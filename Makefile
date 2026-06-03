.PHONY: format check-format

format:
	julia -e 'using Pkg; Pkg.add("JuliaFormatter")' 
	julia -e 'using JuliaFormatter; format(".")'
