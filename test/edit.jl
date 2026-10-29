@testset "edit matching" begin
    mktempdir() do dir
        file = joinpath(dir, "a.txt")
        editor = Edit(dir)
        cases = [
            (; name="exact preserves unrelated lines", original="before “untouched”  \ntarget\n", edits=[(; oldText="target", newText="done")], expected="before “untouched”  \ndone\n"),
            (; name="quotes and dash", original="call “hello” — 世界  \nuntouched “quoted”  \n", edits=[(; oldText="call \"hello\" - 世界", newText="done")], expected="done\nuntouched “quoted”  \n"),
            (; name="trailing whitespace", original="x  \nβ\t\nTAIL “line”  \n", edits=[(; oldText="x\nβ", newText="X\nB")], expected="X\nB\nTAIL “line”  \n"),
            (; name="compatibility and UTF-8 offsets", original="pre 🌱 ﬃ ＡﬁΩ\nuntouched “q”  \n", edits=[(; oldText="ffi Afi", newText="ok")], expected="pre 🌱 okΩ\nuntouched “q”  \n"),
            (; name="fuzzy and exact on different lines", original="before “untouched”  \nﬁ fuzzy\nexact  \nend “untouched”  \n", edits=[(; oldText="fi fuzzy", newText="changed"), (; oldText="exact", newText="EXACT")], expected="before “untouched”  \nchanged\nEXACT\nend “untouched”  \n"),
            (; name="fuzzy and exact on same line", original="emoji 🌱 ﬁ and exact “curly”  \n", edits=[(; oldText="fi", newText="FI"), (; oldText="exact", newText="EXACT")], expected="emoji 🌱 FI and EXACT \"curly\"\n"),
            (; name="multiline CRLF and BOM", original="\ufeffstart  \r\nﬁrst  \r\nsecond\t\r\nuntouched “quote”  \r\n", edits=[(; oldText="first\nsecond", newText="middle\r\nline")], expected="\ufeffstart  \r\nmiddle\r\nline\r\nuntouched “quote”  \r\n"),
            (; name="mixed line endings", original="first\r\nﬁ second\nlast\rline", edits=[(; oldText="fi second", newText="changed")], expected="first\r\nchanged\r\nlast\r\nline"),
            (; name="Unicode trailing whitespace", original="x\ufeff\ny", edits=[(; oldText="x\ny", newText="done")], expected="done"),
            (; name="newline and another edit", original="ﬁ\nnext", edits=[(; oldText="fi", newText="FI"), (; oldText="\n", newText="-")], expected="FI-next"),
            (; name="match ends on newline", original="ﬁ\nnext", edits=[(; oldText="fi\n", newText="FI")], expected="FInext"),
            (; name="match starts on newline", original="before  \nﬁ\nafter  ", edits=[(; oldText="\nfi", newText="-FI")], expected="before-FI\nafter  "),
            (; name="matching duplicate normalized lines with context", original="first  \nﬁrst\nthird", edits=[(; oldText="first\nthird", newText="done")], expected="first  \ndone"),
            (; name="exact whitespace target", original="\t", edits=[(; oldText="\t", newText="done")], expected="done"),
        ]
        for case in cases
            @testset "$(case.name)" begin
                write(file, case.original)
                result = execute(editor, (; path="a.txt", edits=case.edits))
                @test !result.iserror
                @test read(file, String) == case.expected
            end
        end
        failures = [
            (; name="exact and fuzzy duplicate", original="“a” and \"a\"", edits=[(; oldText="\"a\"", newText="done")]),
            (; name="fuzzy duplicate", original="ﬁ ﬁ", edits=[(; oldText="fi", newText="done")]),
            (; name="fuzzy overlap", original="ﬁrst", edits=[(; oldText="fir", newText="A"), (; oldText="rst", newText="B")]),
            (; name="overlapping occurrences", original="aaa", edits=[(; oldText="aa", newText="done")]),
            (; name="exact duplicates hidden by Unicode composition", original="e\u0301 e\u0301", edits=[(; oldText="\u0301", newText="x")]),
            (; name="one missing edit", original="ﬁ foo", edits=[(; oldText="fi", newText="done"), (; oldText="missing", newText="x")]),
            (; name="empty after normalization", original="abc", edits=[(; oldText="  ", newText="x")]),
            (; name="non-ECMAScript whitespace", original="x\u0085\ny", edits=[(; oldText="x\ny", newText="done")]),
        ]
        for case in failures
            @testset "$(case.name)" begin
                write(file, case.original)
                result = execute(editor, (; path="a.txt", edits=case.edits))
                @test result.iserror
                @test read(file, String) == case.original
            end
        end
    end
end
