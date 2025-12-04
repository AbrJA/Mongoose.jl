@generated function to_struct(::Type{T}, dict::Dict{String,String}) where T
    fnames = fieldnames(T)
    ftypes = fieldtypes(T)
    exprs = [:(
        let val = dict[$(string(fname))]
            $(
                if ftype === String
                    :(val)
                elseif ftype === Bool
                    :(lowercase(val) in ("true", "1", "yes"))
                else
                    :(parse($ftype, val))
                end
            )
        end
    ) for (fname, ftype) in zip(fnames, ftypes)]
    return :(T($(exprs...)))
end

struct Driver
    id::Int
    name::String
    years_experience::Float64
    active::Bool
end

d = Dict(
    "id" => "42",
    "name" => "Alice",
    "years_experience" => "3.5",
    "active" => "true"
)


using BenchmarkTools

@benchmark to_struct(Driver, d)
