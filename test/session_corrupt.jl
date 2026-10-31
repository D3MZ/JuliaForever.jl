using Test, JuliaForever, SQLite, JSON3
import JuliaForever.History as CorruptHistory
import JuliaForever.SessionCatalog as CorruptCatalog
import JuliaForever.Durable as CorruptDurable

struct UnexpectedHistoryText <: AbstractString end
Base.codeunits(::UnexpectedHistoryText) = error("unexpected decoding failure")
Base.ncodeunits(::UnexpectedHistoryText) = error("unexpected decoding failure")
