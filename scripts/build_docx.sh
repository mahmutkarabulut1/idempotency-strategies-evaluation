#!/usr/bin/env bash
# Produce a Word .docx of the manuscript via Pandoc.
#  - resolves \ref{...} to real numbers using paper/main.aux (from the LaTeX build)
#  - renders \cite{...} as an IEEE-numbered reference list (citeproc + ieee.csl)
#  - includes figures (PNG) and the auto-generated result tables
# Output: paper/article.docx
set -euo pipefail
cd "$(dirname "$0")/../paper"

[ -f main.aux ] || { echo "main.aux missing; build main.tex first (make)"; exit 1; }
[ -f ieee.csl ] || curl -fsSL https://raw.githubusercontent.com/citation-style-language/styles/master/ieee.csl -o ieee.csl

# 1) label -> number substitutions from the .aux
grep '\\newlabel' main.aux | sed -E 's/\\newlabel\{([^}]+)\}\{\{([^}]+)\}.*/\1 \2/' > .labels.txt
: > .refsub.sed
while read -r label num; do
  esc=$(printf '%s' "$label" | sed 's/[.[\*^$/]/\\&/g')
  printf 's/\\\\ref\{%s\}/%s/g\n' "$esc" "$num" >> .refsub.sed
done < .labels.txt

# 2) build a pandoc-friendly source from the shared body
{
  cat <<'PRE'
\documentclass{article}
\usepackage{graphicx,booktabs,amsmath,array,url,xcolor}
\title{A Comparative Experimental Evaluation of Idempotency and Distributed
Locking Strategies under High Concurrency and Fault Conditions}
\author{Author Name\\ Affiliation, City, Country\\ email@example.com}
\date{}
\begin{document}
\maketitle
PRE
  sed -E \
    -e 's/\\IEEEPARstart\{(.)\}\{([A-Za-z]*)\}/\1\2/g' \
    -e 's/\\begin\{IEEEkeywords\}/\\medskip\\noindent\\textbf{Index Terms---} /' \
    -e 's/\\end\{IEEEkeywords\}//' \
    -e 's/\\IfFileExists\{[^}]*\}\{\\input\{([^}]*)\}\}\{\}/\\input{\1}/g' \
    -e '/\\bibliographystyle/d' \
    -e 's/\\bibliography\{references\}/\\section*{References}/' \
    body.tex | sed -E -f .refsub.sed
  echo '\end{document}'
} > .docx_src.tex

# 3) pandoc (in container) -> docx
docker run --rm -v "$(cd ..; pwd)":/work -w /work/paper pandoc/core:latest \
  .docx_src.tex -f latex -o article.docx \
  --citeproc --bibliography=references.bib --csl=ieee.csl \
  --resource-path=.:../results/figures

rm -f .labels.txt .refsub.sed
echo "wrote paper/article.docx ($(du -h article.docx | cut -f1))"
