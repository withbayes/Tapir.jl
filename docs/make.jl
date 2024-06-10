using Documenter, DocumenterCitations, Tapir

DocMeta.setdocmeta!(
    Tapir,
    :DocTestSetup,
    quote
        using Tapir
    end,
)

makedocs(
    sitename="Tapir.jl",
    format=Documenter.HTML(;
        mathengine = Documenter.KaTeX(
            Dict(
                :macros => Dict(
                    "\\RR" => "\\mathbb{R}",
                ),
            )
        ),
    ),
    modules=[Tapir],
    checkdocs=:none,
    plugins=[
        CitationBibliography(joinpath(@__DIR__, "src", "refs.bib"); style=:numeric),
    ],
    pages = [
        "Tapir.jl" => "index.md",
        "Understanding Tapir.jl" => [
            "Algorithmic Differentiation" => "algorithmic_differentiation.md",
            "Tapir.jl's Mathematical Interpration of Julia Functions" => "mathematical_interpretation.md",
            "AD Without Control Flow" => "single_block_rmad.md",
        ],
    ]
)

deploydocs(repo="github.com/withbayes/Tapir.jl.git", push_preview=true)
