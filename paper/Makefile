# Build the manuscript. `make` builds the self-contained IEEEtran PDF.
# The IEEE Access version (ieeeaccess-main.tex) needs IEEEaccess.cls from the
# official IEEE Access template (see README.md); build it there / on Overleaf.
main.pdf: main.tex body.tex references.bib results_table.tex fault_table.tex
	pdflatex -interaction=nonstopmode main.tex
	bibtex main
	pdflatex -interaction=nonstopmode main.tex
	pdflatex -interaction=nonstopmode main.tex

clean:
	rm -f *.aux *.bbl *.blg *.log *.out main.pdf ieeeaccess-main.pdf

.PHONY: clean
