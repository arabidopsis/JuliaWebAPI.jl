
function make_vargs(vargs)
    arr = Tuple[]
    for (n, v) in vargs
        push!(arr, (Symbol(n), v))
    end
    arr
end

function isvalidcmd(cmd)
    isempty(cmd) && return false
    ((cmd[1] == ':') || Base.is_id_start_char(cmd[1])) || return false
    for c in cmd
        Base.is_id_char(c) || return false
    end
    true
end


function http_handler(apis::Channel{APIInvoker{T,F}}, preproc::Function, req::HTTP.Request) where {T,F}
    target = getfield(req, :target)

    res = HTTP.Response(500)

    try
        comps = split(target, '?', limit=2, keepempty=false)
        if isempty(comps)
            res = HTTP.Response(404)
        else
            res = preproc(req)
            if res === nothing
                path = popfirst!(comps)
                data_dict = isempty(comps) ? Dict{String,String}() : HTTP.queryparams(comps[1])
                parts = HTTP.parse_multipart_form(req)
                if parts !== nothing
                    for part in parts
                        data_dict[part.name] = String(part.data)
                    end
                end

                args = map(String, split(path, '/', keepempty=false))
                if isempty(args) || !isvalidcmd(args[1])
                    res = HTTP.Response(404)
                else
                    cmd = popfirst!(args)
                    @info("waiting for a handler")
                    api = take!(apis)
                    try
                        if isempty(data_dict)
                            @debug("calling", cmd, args)
                            res = httpresponse(api.format, apicall(api, cmd, args...))
                        else
                            vargs = make_vargs(data_dict)
                            @debug("calling", cmd, args, vargs)
                            res = httpresponse(api.format, apicall(api, cmd, args...; vargs...))
                        end
                    finally
                        put!(apis, api)
                    end
                end
            end
        end
    catch e
        @error("Exception in handler: ", exception=(e, catch_backtrace()))
        res = HTTP.Response(500)
    end
    @debug("response", res)
    return res
end

default_preproc(req::HTTP.Request) = nothing

# add a multipart form handler, provide default
struct HttpRpcServer{T,F}
    api::Channel{APIInvoker{T,F}}
    handler::Function
end

HttpRpcServer(api::APIInvoker{T,F}, preproc::Function=default_preproc) where {T,F} = HttpRpcServer([api], preproc)
function HttpRpcServer(apis::Vector{APIInvoker{T,F}}, preproc::Function=default_preproc) where {T,F}
    api = Channel{APIInvoker{T,F}}(length(apis))
    for member in apis
        put!(api, member)
    end

    handler_fn = (req)->JuliaWebAPI.http_handler(api, preproc, req)


    handler = HTTP.streamhandler(handler_fn)
    HttpRpcServer{T,F}(api, (req) -> handler(req))

end

run_http(api::Union{Vector{APIInvoker{T,F}},APIInvoker{T,F}}, port::Int, preproc::Function=default_preproc; kwargs...) where {T,F} = run_http(HttpRpcServer(api, preproc), port; kwargs...)
function run_http(httprpc::HttpRpcServer{T,F}, port::Int; kwargs...) where {T,F}
    @info("running HTTP RPC server...")
    HTTP.listen("127.0.0.1", port; kwargs...) do stream
        httprpc.handler(stream)
    end
end
