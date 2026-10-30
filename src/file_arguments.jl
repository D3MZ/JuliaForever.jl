module FileArguments

using Base64, Unicode, HTTP
import ..JuliaForever: Image, imageformat, fileurlpath

function parse(args)
    files = String[]
    messages = String[]
    for arg in positional(args)
        if startswith(arg, "@")
            push!(files, chop(arg; head=1, tail=0))
        else
            push!(messages, arg)
        end
    end
    (; files, messages)
end

positional(args) = positional(args, findfirst(==("--"), args))
positional(args, ::Nothing) = args
positional(args, index::Integer) = Iterators.flatten((view(args, 1:index-1), view(args, index+1:length(args))))

function resolve(file, cwd)
    normalized = chopprefix(replace(file, r"[\u00a0\u2000-\u200a\u202f\u205f\u3000]" => " "), "@")
    path = abspath(cwd, expanduser(fileurl(normalized)))
    narrow = replace(path, r" (AM|PM)\."i => s"\u202f\1.")
    nfd = Unicode.normalize(path, :NFD)
    curly = replace(path, "'" => "’")
    combined = replace(nfd, "'" => "’")
    paths = (path, narrow, nfd, curly, combined)
    resolved(paths, findfirst(ispath, paths))
end

resolved(paths, ::Nothing) = first(paths)
resolved(paths, index::Integer) = paths[index]
fileurl(text) = startswith(text, "file://") ? fileurl(HTTP.URI(text), text) : text
fileurl(uri::HTTP.URI, text) = fileurl(uri, text, uri.host)
fileurl(uri, text, host) = host in ("", "localhost") ? fileurlpath(text) : text

function load(files, cwd)
    text = IOBuffer()
    images = Image[]
    for file in files
        path = resolve(file, cwd)
        bytes = read(path)
        isempty(bytes) || append!(text, images, path, bytes, imageformat(bytes))
    end
    (; text=String(take!(text)), images)
end

function textcontent(bytes)
    value = String(bytes)
    clean = join(isvalid(char) ? char : '\ufffd' for char in value)
    String(chopprefix(clean, "\ufeff"))
end

function append!(output, images, path, bytes, ::Nothing)
    print(output, "<file name=\"", path, "\">\n", textcontent(bytes), "\n</file>\n")
end

function append!(output, images, path, bytes, format::MIME"image/png")
    sniff = @view bytes[1:min(length(bytes), 4100)]
    appendpng!(output, images, path, bytes, format, staticpng(sniff))
end
appendpng!(output, images, path, bytes, format, ::Nothing) = append!(output, images, path, bytes, nothing)
appendpng!(output, images, path, bytes, format, ::MIME"image/png") = appendimage!(output, images, path, bytes, format)

function staticpng(bytes)
    length(bytes) >= 16 && bytes[9:16] == UInt8[0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52] || return nothing
    offset = 9
    while offset + 7 <= length(bytes)
        chunk = @view bytes[offset+4:offset+7]
        chunk == codeunits("acTL") && return nothing
        chunk == codeunits("IDAT") && break
        size = foldl((n, byte) -> 256n + Int(byte), @view(bytes[offset:offset+3]); init=0)
        next = offset + 12 + size
        next <= length(bytes) || break
        offset = next
    end
    MIME"image/png"()
end
append!(output, images, path, bytes, format::Union{MIME"image/jpeg", MIME"image/gif", MIME"image/webp"}) = appendimage!(output, images, path, bytes, format)

function appendimage!(output, images, path, bytes, format::MIME)
    print(output, "<file name=\"", path, "\"></file>\n")
    push!(images, Image(string(format), base64encode(bytes)))
end

function append!(output, images, path, bytes, ::MIME"image/bmp")
    print(output, "<file name=\"", path, "\">[Image omitted: could not be converted to a supported inline image format.]</file>\n")
end
append!(output, images, path, bytes, ::MIME) = append!(output, images, path, bytes, nothing)

end
