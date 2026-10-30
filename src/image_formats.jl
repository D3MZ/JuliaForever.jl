const inlinebytes = 3 * (div(9 * 1024 * 1024, 8) - 1)
const inlinemessage = "Image exceeds the inline image size limit"
const imagewidth = 2000
readlimit(::Union{MIME"image/gif", MIME"image/webp"}) = inlinebytes
limitmessage(::Union{MIME"image/gif", MIME"image/webp"}) = inlinemessage

function readimagebytes!(io, ::Union{MIME"image/gif", MIME"image/webp"}, bytes, limit)
    while length(bytes) <= limit && !eof(io)
        append!(bytes, read(io, min(64 * 1024, limit + 1 - length(bytes))))
    end
    nothing
end

inlineproblem(bytes) = length(bytes) <= inlinebytes ? nothing : inlinemessage
dimensionproblem(width, height) = 0 < width <= imagewidth && 0 < height <= imagewidth ? nothing : "Image dimensions exceed the supported limit"

imageproblem(::MIME"image/gif", bytes) = gifsize(bytes, inlineproblem(bytes))
gifsize(bytes, problem::String) = problem
function gifsize(bytes, ::Nothing)
    length(bytes) >= 13 || return "image/gif structure is not supported"
    width, height = little(bytes, 7, 2), little(bytes, 9, 2)
    gifdimensions(bytes, width, height, dimensionproblem(width, height))
end
gifdimensions(bytes, width, height, problem::String) = problem
function gifdimensions(bytes, width, height, ::Nothing)
    flags = bytes[11]
    colors = iszero(flags & 0x80) ? 0 : 3 * (1 << (Int(flags & 0x07) + 1))
    gifproblem(bytes, 14 + colors)
end

abstract type GIFRecord end
struct GIFTrailer <: GIFRecord end
struct GIFExtension <: GIFRecord end
struct GIFImage <: GIFRecord end
struct GIFInvalid <: GIFRecord end
const gifrecords = Dict{UInt8, GIFRecord}(0x3b => GIFTrailer(), 0x21 => GIFExtension(), 0x2c => GIFImage())

abstract type GIFFrame end
struct GIFEmpty <: GIFFrame end
struct GIFStatic <: GIFFrame
    width::Int
    height::Int
end
abstract type GIFStatus end
struct GIFReading <: GIFStatus end
struct GIFDone <: GIFStatus
    problem::Union{Nothing, String}
end

mutable struct GIFScan
    bytes::Vector{UInt8}
    position::Int
    frame::GIFFrame
    status::GIFStatus
end

function gifproblem(bytes, position)
    scan = GIFScan(bytes, position, GIFEmpty(), GIFReading())
    for record in scan
        gifrecord!(scan, record)
    end
    gifresult(scan.status)
end
Base.iterate(scan::GIFScan) = gifiterate(scan, scan.status)
Base.iterate(scan::GIFScan, ::Nothing) = gifiterate(scan, scan.status)
gifiterate(scan, ::GIFDone) = nothing
function gifiterate(scan, ::GIFReading)
    scan.position <= length(scan.bytes) || return nothing
    marker = scan.bytes[scan.position]
    scan.position += 1
    get(gifrecords, marker, GIFInvalid()), nothing
end
gifresult(::GIFReading) = "image/gif structure is not supported"
gifresult(result::GIFDone) = result.problem
gifinvalid!(scan) = (scan.status = GIFDone("image/gif structure is not supported"))
gifrecord!(scan, ::GIFInvalid) = gifinvalid!(scan)
gifrecord!(scan, ::GIFTrailer) = giftrailer!(scan, scan.frame)
giftrailer!(scan, ::GIFEmpty) = gifinvalid!(scan)
giftrailer!(scan, frame::GIFStatic) = (scan.status = GIFDone(gifdecode(scan.bytes, frame) ? nothing : "image/gif data is not supported"))
gifrecord!(scan, ::GIFImage) = gifframe!(scan, scan.frame)
gifframe!(scan, ::GIFStatic) = (scan.status = GIFDone("Animated GIF is not supported"))

function gifrecord!(scan, ::GIFExtension)
    scan.position <= length(scan.bytes) || return gifinvalid!(scan)
    scan.position += 1
    gifsubblocks!(scan)
end

function gifframe!(scan, ::GIFEmpty)
    bytes, position = scan.bytes, scan.position
    position + 8 <= length(bytes) || return gifinvalid!(scan)
    w, h = little(bytes, position + 4, 2), little(bytes, position + 6, 2)
    gifframe!(scan, w, h, dimensionproblem(w, h))
end
gifframe!(scan, width, height, problem::String) = (scan.status = GIFDone(problem))
function gifframe!(scan, width, height, ::Nothing)
    flags = scan.bytes[scan.position + 8]
    colors = iszero(flags & 0x80) ? 0 : 3 * (1 << (Int(flags & 0x07) + 1))
    scan.position += 9 + colors
    scan.position <= length(scan.bytes) || return gifinvalid!(scan)
    scan.position += 1
    scan.frame = GIFStatic(width, height)
    gifsubblocks!(scan)
end

function gifsubblocks!(scan)
    bytes = scan.bytes
    while scan.position <= length(bytes)
        size = Int(bytes[scan.position])
        scan.position += 1
        iszero(size) && return nothing
        scan.position + size - 1 <= length(bytes) || return gifinvalid!(scan)
        scan.position += size
    end
    gifinvalid!(scan)
end

mutable struct GIFInput
    bytes::Vector{UInt8}
    position::Int
end
const gifinput = Base.ScopedValues.ScopedValue{GIFInput}()

function gifread(file::Ptr{Cvoid}, output::Ptr{UInt8}, requested::Cint)::Cint
    input = gifinput[]
    count = clamp(Int(requested), 0, length(input.bytes) - input.position + 1)
    if count > 0
        GC.@preserve input unsafe_copyto!(output, pointer(input.bytes, input.position), count)
        input.position += count
    end
    Cint(count)
end

mutable struct GIFDecoder
    file::Ptr{Cvoid}
    frame::GIFStatic
    row::Vector{UInt8}
    status::GIFStatus
end
const gifdecodedrecords = Dict{Cint, GIFRecord}(2 => GIFImage(), 3 => GIFExtension(), 4 => GIFTrailer())

Base.iterate(decoder::GIFDecoder) = gifnext(decoder, decoder.status)
Base.iterate(decoder::GIFDecoder, ::Nothing) = gifnext(decoder, decoder.status)
gifnext(decoder, ::GIFDone) = nothing
function gifnext(decoder, ::GIFReading)
    record = Ref{Cint}(0)
    ccall((:DGifGetRecordType, libgif), Cint, (Ptr{Cvoid}, Ref{Cint}), decoder.file, record) == 1 || return (GIFInvalid(), nothing)
    get(gifdecodedrecords, record[], GIFInvalid()), nothing
end
gifdecoded!(decoder, ::GIFInvalid) = gifinvalid!(decoder)
gifdecoded!(decoder, ::GIFTrailer) = (decoder.status = GIFDone(nothing))
gifdecodedresult(::GIFReading) = false
gifdecodedresult(result::GIFDone) = gifdecodedresult(result.problem)
gifdecodedresult(::Nothing) = true
gifdecodedresult(::String) = false

function gifdecoded!(decoder, ::GIFImage)
    ccall((:DGifGetImageDesc, libgif), Cint, (Ptr{Cvoid},), decoder.file) == 1 || return gifinvalid!(decoder)
    for _ in 1:decoder.frame.height
        ccall((:DGifGetLine, libgif), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Cint), decoder.file, decoder.row, decoder.frame.width) == 1 || return gifinvalid!(decoder)
    end
    nothing
end

function gifdecoded!(decoder, ::GIFExtension)
    code, block = Ref{Cint}(0), Ref{Ptr{UInt8}}(C_NULL)
    ccall((:DGifGetExtension, libgif), Cint, (Ptr{Cvoid}, Ref{Cint}, Ref{Ptr{UInt8}}), decoder.file, code, block) == 1 || return gifinvalid!(decoder)
    while block[] != C_NULL
        ccall((:DGifGetExtensionNext, libgif), Cint, (Ptr{Cvoid}, Ref{Ptr{UInt8}}), decoder.file, block) == 1 || return gifinvalid!(decoder)
    end
    nothing
end

function gifdecode(bytes, frame::GIFStatic)
    Base.ScopedValues.with(gifinput => GIFInput(bytes, 1)) do
        reader = @cfunction(gifread, Cint, (Ptr{Cvoid}, Ptr{UInt8}, Cint))
        status = Ref{Cint}(0)
        file = ccall((:DGifOpen, libgif), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ref{Cint}), C_NULL, reader, status)
        file == C_NULL && return false
        try
            decoder = GIFDecoder(file, frame, Vector{UInt8}(undef, frame.width), GIFReading())
            for record in decoder
                gifdecoded!(decoder, record)
            end
            gifdecodedresult(decoder.status)
        finally
            ccall((:DGifCloseFile, libgif), Cint, (Ptr{Cvoid}, Ref{Cint}), file, status)
        end
    end
end

imageproblem(::MIME"image/webp", bytes) = webpsize(bytes, inlineproblem(bytes))
webpsize(bytes, problem::String) = problem
function webpsize(bytes, ::Nothing)
    width, height = Ref{Cint}(0), Ref{Cint}(0)
    ccall((:WebPGetInfo, libwebp), Cint, (Ptr{UInt8}, Csize_t, Ref{Cint}, Ref{Cint}), bytes, length(bytes), width, height) == 1 || return "image/webp structure is not supported"
    length(bytes) >= 21 && @view(bytes[13:16]) == codeunits("VP8X") && !iszero(bytes[21] & 0x02) && return "Animated WebP is not supported"
    webpdimensions(bytes, width[], height[], dimensionproblem(width[], height[]))
end
webpdimensions(bytes, width, height, problem::String) = problem
function webpdimensions(bytes, width, height, ::Nothing)
    stride = 4 * width
    output = Vector{UInt8}(undef, stride * height)
    decoded = ccall((:WebPDecodeRGBAInto, libwebp), Ptr{UInt8}, (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t, Cint), bytes, length(bytes), output, length(output), stride)
    decoded == C_NULL ? "image/webp data is not supported" : nothing
end
