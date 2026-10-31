using Test, JSON3, JuliaForever

import JuliaForever.Durable as D

reason(x) = x isa D.Rejected ? x.reason : nothing
ids(rows) = [row.id for row in rows]
