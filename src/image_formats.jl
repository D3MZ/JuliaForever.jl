const inlinebytes = 3 * (div(9 * 1024 * 1024, 8) - 1)
const inlinemessage = "Image exceeds the inline image size limit"
const imagewidth = 2000
const animationpixels = 64_000_000
const animationmessage = "Image animation exceeds the supported limit"
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

imageproblem(::MIME"image/gif", bytes) = gifresult(gifsize(bytes, inlineproblem(bytes)))
readproblem(::MIME"image/gif", bytes) = gifreadresult(gifsize(bytes, inlineproblem(bytes)))
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
    gifproblem(bytes, 14 + colors, div(colors, 3))
end

abstract type GIFRecord end
struct GIFTrailer <: GIFRecord end
struct GIFExtension <: GIFRecord end
struct GIFImage <: GIFRecord end
struct GIFInvalid <: GIFRecord end
const gifrecords = Dict{UInt8, GIFRecord}(0x3b => GIFTrailer(), 0x21 => GIFExtension(), 0x2c => GIFImage())

abstract type GIFData end
struct GIFUnique <: GIFData end
struct GIFRepeated <: GIFData end

struct GIFFrame
    width::Int
    height::Int
    colors::Int
    data::GIFData
end
abstract type GIFStatus end
struct GIFReading <: GIFStatus end
struct GIFDone <: GIFStatus
    problem::Union{Nothing, String}
end

mutable struct GIFScan
    bytes::Vector{UInt8}
    position::Int
    frames::Vector{GIFFrame}
    pixels::Int
    seen::Set{Vector{UInt8}}
    status::GIFStatus
    colors::Int
end

function gifproblem(bytes, position, colors)
    scan = GIFScan(bytes, position, GIFFrame[], 0, Set{Vector{UInt8}}(), GIFReading(), colors)
    for record in scan
        gifrecord!(scan, record)
    end
    scan
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
gifresult(result::String) = result
gifresult(scan::GIFScan) = gifresult(scan.status)
gifreadresult(result::String) = result
gifreadresult(scan::GIFScan) = gifreadresult(gifresult(scan.status), scan.frames)
gifreadresult(problem::String, frame) = problem
gifreadresult(::Nothing, frames::Vector{GIFFrame}) = any(frame -> iszero(frame.colors), frames) ? "image/gif color table is missing" : nothing
gifinvalid!(scan) = (scan.status = GIFDone("image/gif structure is not supported"))
gifrecord!(scan, ::GIFInvalid) = gifinvalid!(scan)
gifrecord!(scan, ::GIFTrailer) = (scan.status = GIFDone(!isempty(scan.frames) && gifdecode(scan.bytes, scan.frames) ? nothing : "image/gif data is not supported"))
gifrecord!(scan, ::GIFImage) = gifframe!(scan)

function gifrecord!(scan, ::GIFExtension)
    scan.position <= length(scan.bytes) || return gifinvalid!(scan)
    scan.position += 1
    gifsubblocks!(scan)
end

function gifframe!(scan)
    bytes, position = scan.bytes, scan.position
    position + 8 <= length(bytes) || return gifinvalid!(scan)
    w, h = little(bytes, position + 4, 2), little(bytes, position + 6, 2)
    gifframe!(scan, w, h, dimensionproblem(w, h))
end
gifframe!(scan, width, height, problem::String) = (scan.status = GIFDone(problem))
function gifframe!(scan, width, height, ::Nothing)
    start = scan.position
    flags = scan.bytes[start + 8]
    colors = iszero(flags & 0x80) ? 0 : 3 * (1 << (Int(flags & 0x07) + 1))
    scan.position += 9 + colors
    scan.position <= length(scan.bytes) || return gifinvalid!(scan)
    scan.position += 1
    gifsubblocks!(scan)
    gifframe!(scan, width, height, max(scan.colors, div(colors, 3)), start, scan.status)
end

gifframe!(scan, width, height, colors, start, ::GIFDone) = nothing
function gifframe!(scan, width, height, colors, start, ::GIFReading)
    data = scan.bytes[start:scan.position-1]
    kind = gifdata!(scan.seen, data)
    gifbudget!(scan, width, height, kind)
    push!(scan.frames, GIFFrame(width, height, colors, kind))
end
function gifdata!(seen, data)
    data in seen && return GIFRepeated()
    push!(seen, data)
    GIFUnique()
end
gifbudget!(scan, width, height, ::GIFRepeated) = nothing
function gifbudget!(scan, width, height, ::GIFUnique)
    scan.pixels += width * height
    scan.pixels <= animationpixels || (scan.status = GIFDone(animationmessage))
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
    frames::Vector{GIFFrame}
    index::Int
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
    decoder.index += 1
    frame = decoder.frames[decoder.index]
    gifdecoded!(decoder, frame, frame.data)
end

function gifdecoded!(decoder, frame, ::GIFUnique)
    resize!(decoder.row, frame.width)
    for _ in 1:frame.height
        ccall((:DGifGetLine, libgif), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Cint), decoder.file, decoder.row, frame.width) == 1 || return gifinvalid!(decoder)
    end
    nothing
end

function gifdecoded!(decoder, frame, ::GIFRepeated)
    code, block = Ref{Cint}(0), Ref{Ptr{UInt8}}(C_NULL)
    ccall((:DGifGetCode, libgif), Cint, (Ptr{Cvoid}, Ref{Cint}, Ref{Ptr{UInt8}}), decoder.file, code, block) == 1 || return gifinvalid!(decoder)
    while block[] != C_NULL
        ccall((:DGifGetCodeNext, libgif), Cint, (Ptr{Cvoid}, Ref{Ptr{UInt8}}), decoder.file, block) == 1 || return gifinvalid!(decoder)
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

function gifdecode(bytes, frames::Vector{GIFFrame})
    Base.ScopedValues.with(gifinput => GIFInput(bytes, 1)) do
        reader = @cfunction(gifread, Cint, (Ptr{Cvoid}, Ptr{UInt8}, Cint))
        status = Ref{Cint}(0)
        file = ccall((:DGifOpen, libgif), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ref{Cint}), C_NULL, reader, status)
        file == C_NULL && return false
        try
            decoder = GIFDecoder(file, frames, 0, UInt8[], GIFReading())
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
    webpdimensions(bytes, width[], height[], dimensionproblem(width[], height[]))
end
webpdimensions(bytes, width, height, problem::String) = problem
function webpdimensions(bytes, width, height, ::Nothing)
    length(bytes) >= 21 && @view(bytes[13:16]) == codeunits("VP8X") && !iszero(bytes[21] & 0x02) && return webpanimation(bytes)
    stride = 4 * width
    output = Vector{UInt8}(undef, stride * height)
    decoded = ccall((:WebPDecodeRGBAInto, libwebp), Ptr{UInt8}, (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t, Cint), bytes, length(bytes), output, length(output), stride)
    decoded == C_NULL ? "image/webp data is not supported" : nothing
end

struct WebPData
    bytes::Ptr{UInt8}
    size::Csize_t
end

function webpanimation(bytes)
    GC.@preserve bytes begin
        data = Ref(WebPData(pointer(bytes), length(bytes)))
        decoder = ccall((:WebPAnimDecoderNewInternal, libwebpdemux), Ptr{Cvoid}, (Ref{WebPData}, Ptr{Cvoid}, Cint), data, C_NULL, 0x0107)
        decoder == C_NULL && return "image/webp data is not supported"
        try
            info = Ref(ntuple(_ -> UInt32(0), 9))
            ccall((:WebPAnimDecoderGetInfo, libwebpdemux), Cint, (Ptr{Cvoid}, Ref{NTuple{9, UInt32}}), decoder, info) == 1 || return "image/webp data is not supported"
            width, height, _, _, frames = info[][1:5]
            UInt64(width) * height * frames <= animationpixels || return animationmessage
            output, timestamp = Ref{Ptr{UInt8}}(C_NULL), Ref{Cint}(0)
            while ccall((:WebPAnimDecoderHasMoreFrames, libwebpdemux), Cint, (Ptr{Cvoid},), decoder) != 0
                ccall((:WebPAnimDecoderGetNext, libwebpdemux), Cint, (Ptr{Cvoid}, Ref{Ptr{UInt8}}, Ref{Cint}), decoder, output, timestamp) == 1 || return "image/webp data is not supported"
            end
            nothing
        finally
            ccall((:WebPAnimDecoderDelete, libwebpdemux), Cvoid, (Ptr{Cvoid},), decoder)
        end
    end
end
