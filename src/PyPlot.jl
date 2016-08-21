__precompile__()

module PyPlot

using PyCall
import PyCall: PyObject, pygui, pycall, pyexists
import Base: convert, ==, isequal, hash, getindex, setindex!, haskey, keys, show, mimewritable
export Figure, plt, matplotlib, pygui, withfig

using Compat
@compat import Base.show

# Wrapper around matplotlib Figure, supporting graphics I/O and pretty display
type Figure
    o::PyObject
end

###########################################################################
# Julia 0.4 help system: define a documentation object
# that lazily looks up help from a PyObject via zero or more keys.
# This saves us time when loading PyPlot, since we don't have
# to load up all of the documentation strings right away.
immutable LazyHelp
    o::PyObject
    keys::Tuple{Vararg{Compat.String}}
    LazyHelp(o::PyObject) = new(o, ())
    LazyHelp(o::PyObject, k::AbstractString) = new(o, (k,))
    LazyHelp(o::PyObject, k1::AbstractString, k2::AbstractString) = new(o, (k1,k2))
    LazyHelp(o::PyObject, k::Tuple{Vararg{AbstractString}}) = new(o, k)
end
@compat function show(io::IO, ::MIME"text/plain", h::LazyHelp)
    o = h.o
    for k in h.keys
        o = o[k]
    end
    if haskey(o, "__doc__")
        print(io, convert(AbstractString, o["__doc__"]))
    else
        print(io, "no Python docstring found for ", o)
    end
end
Base.show(io::IO, h::LazyHelp) = @compat show(io, "text/plain", h)
function Base.Docs.catdoc(hs::LazyHelp...)
    Base.Docs.Text() do io
        for h in hs
            @compat show(io, MIME"text/plain"(), h)
        end
    end
end

###########################################################################
# global PyObject constants that get initialized at runtime.  We
# initialize them here (rather than via "global const foo = ..." in __init__)
# so that their type is known at compile-time.

# remove this once we tag and require a newer PyCall version:
if isdefined(PyCall,:PyNULL)
    PyNULL() = PyCall.PyNULL()
else
    PyNULL() = PyCall.PyObject()
end

const matplotlib = PyNULL()
const plt = PyNULL()
const Gcf = PyNULL()
const orig_draw = PyNULL()
const orig_gcf = PyNULL()
const orig_figure = PyNULL()
const orig_show = PyNULL()
const mplot3d = PyNULL()
const axes3D = PyNULL()
const art3D = PyNULL()

###########################################################################
# file formats supported by Agg backend, from MIME types
const aggformats = Dict("application/eps" => "eps",
                        "image/eps" => "eps",
                        "application/pdf" => "pdf",
                        "image/png" => "png",
                        "application/postscript" => "ps",
                        "image/svg+xml" => "svg")

function isdisplayok()
    for mime in keys(aggformats)
        if displayable(mime)
            return true
        end
    end
    false
end

###########################################################################
# We allow the user to turn on or off the Python gui interactively via
# pygui(true/false).  This is done by loading pyplot with a GUI backend
# if possible, then switching to a Julia-display backend (if available)

# return (backend,gui) tuple
function find_backend(matplotlib::PyObject)
    gui2matplotlib = Dict(:wx=>"WXAgg",:gtk=>"GTKAgg",:gtk3=>"GTK3Agg",
                          :qt=>"Qt4Agg",:tk=>"TkAgg")
    conda = PyCall.conda || !isempty(PyCall.anaconda_conda())
    if is_linux()
        guis = [:tk, :gtk3, :gtk, :qt, :wx]
    elseif is_apple() && conda # partially work around #164
        guis = [:qt, :tk, :wx, :gtk, :gtk3]
    else
        guis = [:tk, :qt, :wx, :gtk, :gtk3]
    end
    options = [(g,gui2matplotlib[g]) for g in guis]

    matplotlib2gui = Dict("wx"=>:wx, "wxagg"=>:wx,
                          "gtkagg"=>:gtk, "gtk"=>:gtk,"gtkcairo"=>:gtk,
                          "gtk3agg"=>:gtk3, "gtk3"=>:gtk3,"gtk3cairo"=>:gtk3,
                          "qt4agg"=>:qt, "tkagg"=>:tk,
                          "agg"=>:none,"ps"=>:none,"pdf"=>:none,
                          "svg"=>:none,"cairo"=>:none,"gdk"=>:none,
                          "module://gr.matplotlib.backend_gr"=>:gr)

    qt2gui = Dict("pyqt4"=>:qt_pyqt4, "pyside"=>:qt_pyside)

    rcParams = PyDict(matplotlib["rcParams"])
    default = lowercase(get(ENV, "MPLBACKEND",
                            get(rcParams, "backend", "none")))
    if haskey(matplotlib2gui,default)
        defaultgui = matplotlib2gui[default]

        # if the user explicitly requested a particular GUI,
        # it makes sense to ensure that the relevant Conda
        # package is installed (if we are using Conda).
        if conda
            if defaultgui == :qt
                # default to pyqt rather than pyside, as below:
                defaultgui = haskey(rcParams,"backend.qt4") ? qt2gui[lowercase(rcParams["backend.qt4"])] : :qt_pyqt4
                if defaultgui == :qt_pyside
                    pyimport_conda("PySide", "pyside")
                else
                    pyimport_conda("PyQt4", "pyqt")
                end
            elseif defaultgui == :wx
                pyimport_conda("wx", "wxpython")
            end
        end

        insert!(options, 1, (defaultgui,default))
    end

    try
        # We will get an exception when we import pyplot below (on
        # Unix) if an X server is not available, even though
        # pygui_works and matplotlib.use(backend) succeed, at
        # which point it will be too late to switch backends.  So,
        # throw exception (drop to catch block below) if DISPLAY
        # is not set.  [Might be more reliable to test
        # success(`xdpyinfo`), but only if xdpyinfo is installed.]

        if options[1][1] != :none
            @static if is_unix()
                @static if is_apple()
                    nothing
                else
                    ENV["DISPLAY"]
                end
            end
        end

        if PyCall.gui == :default
            # try to ensure that GUI both exists and has a matplotlib backend
            for (g,b) in options
                if g == :none # Matplotlib is configured to be non-interactive
                    pygui(:default)
                    matplotlib[:use](b)
                    matplotlib[:interactive](false)
                    return (b, g)
                elseif g == :gr
                    return (b, g)
                elseif PyCall.pygui_works(g)
                    # must call matplotlib.use *before* loading backends module
                    matplotlib[:use](b)
                    if g == :qt
                        if haskey(rcParams,"backend.qt4")
                            g = qt2gui[lowercase(rcParams["backend.qt4"])]
                        elseif !PyCall.pygui_works(:qt_pyqt4)
                            # both Matplotlib and PyCall default to PyQt4
                            # if it is available, but we need to tell
                            # Matplotlib to use PySide otherwise.
                            rcParams["backend.qt4"] = "PySide"
                        end
                    end
                    if pyexists("matplotlib.backends.backend_" * lowercase(b))
                        isjulia_display[1] || pygui_start(g)
                        matplotlib[:interactive](!isjulia_display[1] && Base.isinteractive())
                        return (b, g)
                    end
                end
            end
            error("no gui found") # go to catch clause below
        else # the user specified a desired backend via pygui(gui)
            gui = pygui()
            matplotlib[:use](gui2matplotlib[gui])
            if (gui==:qt && !PyCall.pygui_works(:qt_pyqt4)) || gui==:qt_pyside
                rcParams["backend.qt4"] = "PySide"
            end
            isjulia_display[1] || pygui_start(gui)
            matplotlib[:interactive](!isjulia_display[1] && Base.isinteractive())
            return (gui2matplotlib[gui], gui)
        end
    catch
        if !isjulia_display[1]
            warn("No working GUI backend found for matplotlib.")
            isjulia_display[1] = true
        end
        pygui(:default)
        matplotlib[:use]("Agg") # GUI not available
        matplotlib[:interactive](false)
        return ("Agg", :none)
    end
end

# initialization -- anything that depends on Python has to go here,
# so that it occurs at runtime (while the rest of PyPlot can be precompiled).
function __init__()
    global const isjulia_display = Bool[isdisplayok()]
    copy!(matplotlib, pyimport_conda("matplotlib", "matplotlib"))
    global const version = try
        convert(VersionNumber, matplotlib[:__version__])
    catch
        v"0.0" # fallback
    end

    backend_gui = find_backend(matplotlib)
    # workaround JuliaLang/julia#8925
    global const backend = backend_gui[1]
    global const gui = backend_gui[2]

    copy!(plt, pyimport("matplotlib.pyplot")) # raw Python module

    pytype_mapping(plt["Figure"], Figure)

    copy!(Gcf, pyimport("matplotlib._pylab_helpers")["Gcf"])
    copy!(orig_gcf, plt["gcf"])
    copy!(orig_figure, plt["figure"])
    plt["gcf"] = gcf
    plt["figure"] = figure

    if isdefined(Main, :IJulia) && Main.IJulia.inited
        Main.IJulia.push_preexecute_hook(force_new_fig)
        Main.IJulia.push_postexecute_hook(display_figs)
        Main.IJulia.push_posterror_hook(close_figs)
    end

    if isjulia_display[1] && gui != :gr && backend != "Agg"
        plt[:switch_backend]("Agg")
        plt[:ioff]()
    end

    copy!(mplot3d, pyimport("mpl_toolkits.mplot3d"))
    copy!(axes3D, pyimport("mpl_toolkits.mplot3d.axes3d"))

    copy!(art3D, pyimport("mpl_toolkits.mplot3d.art3d"))

    init_colormaps()
end

function pygui(b::Bool)
    if !b != isjulia_display[1]
        if backend != "Agg"
            plt[:switch_backend](b ? backend : "Agg")
            b && pygui_start(gui) # make sure event loop is started
            matplotlib[:interactive](b && Base.isinteractive())
        elseif b
            error("No working GUI backend found for matplotlib.")
        end
        isjulia_display[1] = !b
    end
    return b
end

###########################################################################
# Figure methods

PyObject(f::Figure) = f.o
convert(::Type{Figure}, o::PyObject) = Figure(o)
==(f::Figure, g::Figure) = f.o == g.o
==(f::Figure, g::PyObject) = f.o == g
==(f::PyObject, g::Figure) = f == g.o
hash(f::Figure) = hash(f.o)
pycall(f::Figure, args...; kws...) = pycall(f.o, args...; kws...)
@compat (f::Figure)(args...; kws...) = pycall(f.o, PyAny, args...; kws...)
Base.Docs.doc(f::Figure) = Base.Docs.doc(f.o)

getindex(f::Figure, x) = getindex(f.o, x)
setindex!(f::Figure, v, x) = setindex!(f.o, v, x)
haskey(f::Figure, x) = haskey(f.o, x)
keys(f::Figure) = keys(f.o)

for (mime,fmt) in aggformats
    @eval @compat function show(io::IO, m::MIME{Symbol($mime)}, f::Figure)
        if !haskey(pycall(f.o["canvas"]["get_supported_filetypes"], PyDict),
                   $fmt)
            throw(MethodError(@static(VERSION < v"0.5.0-dev+4340" ? writemime : show), (io, m, f)))
        end
        f.o["canvas"][:print_figure](io, format=$fmt, bbox_inches="tight")
    end
    if fmt != "svg"
        @eval mimewritable(::MIME{Symbol($mime)}, f::Figure) = !isempty(f) && haskey(pycall(f.o["canvas"]["get_supported_filetypes"], PyDict), $fmt)
    end
end

# disable SVG output by default, since displaying large SVGs (large datasets)
# in IJulia is slow, and browser SVG display is buggy.  (Similar to IPython.)
const SVG = [false]
mimewritable(::MIME"image/svg+xml", f::Figure) = SVG[1] && !isempty(f) && haskey(pycall(f.o["canvas"]["get_supported_filetypes"], PyDict), "svg")
svg() = SVG[1]
svg(b::Bool) = (SVG[1] = b)

###########################################################################
# In IJulia, we want to automatically display any figures
# at the end of cell execution, and then close them.   However,
# we don't want to display/close figures being used in withfig,
# since the user is keeping track of these in some other way,
# e.g. for interactive widgets.

Base.isempty(f::Figure) = isempty(pycall(f["get_axes"], PyVector))

# We keep a set of figure numbers for the figures used in withfig, because
# for these figures we don't want to auto-display or auto-close them
# when the cell finishes executing.   (We store figure numbers, rather
# than Figure objects, since the latter would prevent the figures from
# finalizing and hence closing.)  Closing the figure removes it from this set.
const withfig_fignums = Set{Int}()

function display_figs() # called after IJulia cell executes
    if isjulia_display[1]
        for manager in Gcf[:get_all_fig_managers]()
            f = manager["canvas"]["figure"]
            if f[:number] ∉ withfig_fignums
                fig = Figure(f)
                isempty(fig) || display(fig)
                pycall(plt["close"], PyAny, f)
            end
        end
    end
end

function close_figs() # called after error in IJulia cell
    if isjulia_display[1]
        for manager in Gcf[:get_all_fig_managers]()
            f = manager["canvas"]["figure"]
            if f[:number] ∉ withfig_fignums
                pycall(plt["close"], PyAny, f)
            end
        end
    end
end

# hook to force new IJulia cells to create new figure objects
const gcf_isnew = [false] # true to force next gcf() to be new figure
force_new_fig() = gcf_isnew[1] = true

# monkey-patch gcf() and figure() so that we can force the creation
# of new figures in new IJulia cells (e.g. after @manipulate commands
# that leave the figure from the previous cell open).

@doc LazyHelp(orig_figure) function figure(args...; kws...)
    gcf_isnew[1] = false
    pycall(orig_figure, PyAny, args...; kws...)
end

@doc LazyHelp(orig_gcf) function gcf()
    if isjulia_display[1] && gcf_isnew[1]
        return figure()
    else
        return pycall(orig_gcf, PyAny)
    end
end

###########################################################################

# export documented pyplot API (http://matplotlib.org/api/pyplot_api.html)
export acorr,annotate,arrow,autoscale,autumn,axes,axhline,axhspan,axis,axvline,axvspan,bar,barbs,barh,bone,box,boxplot,broken_barh,cla,clabel,clf,clim,cohere,colorbar,colors,contour,contourf,cool,copper,csd,delaxes,disconnect,draw,errorbar,eventplot,figaspect,figimage,figlegend,figtext,figure,fill_between,fill_betweenx,findobj,flag,gca,gcf,gci,get_current_fig_manager,get_figlabels,get_fignums,get_plot_commands,ginput,gray,grid,hexbin,hist2D,hlines,hold,hot,hsv,imread,imsave,imshow,ioff,ion,ishold,jet,legend,locator_params,loglog,margins,matshow,minorticks_off,minorticks_on,over,pause,pcolor,pcolormesh,pie,pink,plot,plot_date,plotfile,polar,prism,psd,quiver,quiverkey,rc,rc_context,rcdefaults,rgrids,savefig,sca,scatter,sci,semilogx,semilogy,set_cmap,setp,show,specgram,spectral,spring,spy,stackplot,stem,step,streamplot,subplot,subplot2grid,subplot_tool,subplots,subplots_adjust,summer,suptitle,table,text,thetagrids,tick_params,ticklabel_format,tight_layout,title,tricontour,tricontourf,tripcolor,triplot,twinx,twiny,vlines,waitforbuttonpress,winter,xkcd,xlabel,xlim,xscale,xticks,ylabel,ylim,yscale,yticks

# The following pyplot functions must be handled specially since they
# overlap with standard Julia functions:
#          close, connect, fill, hist, xcorr
import Base: close, connect, fill, step

const plt_funcs = (:acorr,:annotate,:arrow,:autoscale,:autumn,:axes,:axhline,:axhspan,:axis,:axvline,:axvspan,:bar,:barbs,:barh,:bone,:box,:boxplot,:broken_barh,:cla,:clabel,:clf,:clim,:cohere,:colorbar,:colors,:contour,:contourf,:cool,:copper,:csd,:delaxes,:disconnect,:draw,:errorbar,:eventplot,:figaspect,:figimage,:figlegend,:figtext,:fill_between,:fill_betweenx,:findobj,:flag,:gca,:gci,:get_current_fig_manager,:get_figlabels,:get_fignums,:get_plot_commands,:ginput,:gray,:grid,:hexbin,:hlines,:hold,:hot,:hsv,:imread,:imsave,:imshow,:ioff,:ion,:ishold,:jet,:legend,:locator_params,:loglog,:margins,:matshow,:minorticks_off,:minorticks_on,:over,:pause,:pcolor,:pcolormesh,:pie,:pink,:plot,:plot_date,:plotfile,:polar,:prism,:psd,:quiver,:quiverkey,:rc,:rc_context,:rcdefaults,:rgrids,:savefig,:sca,:scatter,:sci,:semilogx,:semilogy,:set_cmap,:setp,:specgram,:spectral,:spring,:spy,:stackplot,:stem,:streamplot,:subplot,:subplot2grid,:subplot_tool,:subplots,:subplots_adjust,:summer,:suptitle,:table,:text,:thetagrids,:tick_params,:ticklabel_format,:tight_layout,:title,:tricontour,:tricontourf,:tripcolor,:triplot,:twinx,:twiny,:vlines,:waitforbuttonpress,:winter,:xkcd,:xlabel,:xlim,:xscale,:xticks,:ylabel,:ylim,:yscale,:yticks)

for f in plt_funcs
    sf = string(f)
    @eval @doc LazyHelp(plt,$sf) function $f(args...; kws...)
        if !haskey(plt, $sf)
            error("matplotlib ", version, " does not have pyplot.", $sf)
        end
        return pycall(plt[$sf], PyAny, args...; kws...)
    end
end

@doc LazyHelp(plt,"step") step(x, y; kws...) = pycall(plt["step"], PyAny, x, y; kws...)

Base.show() = begin pycall(plt[:show], PyObject); nothing; end

close(f::Figure) = close(f[:number])
function close(f::Integer)
    pop!(withfig_fignums, f, f)
    pycall(plt["close"], PyAny, f)
end
close(f::Union{AbstractString,Symbol}) = pycall(plt["close"], PyAny, f)
@doc LazyHelp(plt,"close") close() = pycall(plt["close"], PyAny)

@doc LazyHelp(plt,"connect") connect(s::Union{AbstractString,Symbol}, f::Function) = pycall(plt["connect"], PyAny, s, f)

@doc LazyHelp(plt,"fill") fill(x::AbstractArray,y::AbstractArray, args...; kws...) =
    pycall(plt["fill"], PyAny, x, y, args...; kws...)

# consistent capitalization with mplot3d, avoid conflict with Base.hist2d
@doc LazyHelp(plt,"hist2d") hist2D(args...; kws...) = pycall(plt["hist2d"], PyAny, args...; kws...)

# no way to use method dispatch for hist or xcorr, since their
# argument signatures look too much like Julia's -- just use plt[:hist]

include("colormaps.jl")

###########################################################################
# Support array of string labels in bar chart

function bar{T<:AbstractString}(x::AbstractVector{T}, y; kws...)
    xi = 1:length(x)
    if !any(kw -> kw[1] == :align, kws)
        push!(kws, (:align, "center"))
    end
    p = bar(xi, y; kws...)
    ax = any(kw -> kw[1] == :orientation && lowercase(kw[2]) == "horizontal",
             kws) ? gca()["yaxis"] : gca()["xaxis"]
    ax[:set_ticks](xi)
    ax[:set_ticklabels](x)
    return p
end

bar{T<:Symbol}(x::AbstractVector{T}, y; kws...) =
    bar(map(string, x), y; kws...)

###########################################################################
# Include mplot3d for 3d plotting.

export art3D, Axes3D, surf, mesh, bar3D, contour3D, contourf3D, plot3D, plot_surface, plot_trisurf, plot_wireframe, scatter3D, text2D, text3D, zlabel, zlim, zscale, zticks

const mplot3d_funcs = (:bar3d, :contour3D, :contourf3D, :plot3D, :plot_surface,
                       :plot_trisurf, :plot_wireframe, :scatter3D,
                       :text2D, :text3D)

for f in mplot3d_funcs
    fs = string(f)
    @eval @doc LazyHelp(axes3D,"Axes3D", $fs) function $f(args...; kws...)
        ax = gca(projection="3d")
        pycall(ax[$fs], PyAny, args...; kws...)
    end
end

# TODO: in Julia 0.4, change this to a callable object
@doc LazyHelp(axes3D,"Axes3D") Axes3D(args...; kws...) = pycall(axes3D["Axes3D"], PyAny, args...; kws...)

# correct for annoying mplot3d inconsistency
@doc LazyHelp(axes3D,"Axes3D", "bar3d") bar3D(args...) = bar3d(args...)

# it's annoying to have xlabel etc. but not zlabel
const zlabel_funcs = (:zlabel, :zlim, :zscale, :zticks)
for f in zlabel_funcs
    fs = string("set_", f)
    @eval @doc LazyHelp(axes3D,"Axes3D", $fs) function $f(args...; kws...)
        ax = gca(projection="3d")
        pycall(ax[$fs], PyAny, args...; kws...)
    end
end

# export Matlab-like names

function surf(Z::AbstractMatrix; kws...)
    plot_surface([1:size(Z,1);]*ones(1,size(Z,2)),
                 ones(size(Z,1))*[1:size(Z,2);]', Z; kws...)
end

@doc LazyHelp(axes3D,"Axes3D", "plot_surface") function surf(X, Y, Z::AbstractMatrix, args...; kws...)
    plot_surface(X, Y, Z, args...; kws...)
end

function surf(X, Y, Z::AbstractVector, args...; kws...)
    plot_trisurf(X, Y, Z, args...; kws...)
end

@doc LazyHelp(axes3D,"Axes3D", "plot_wireframe") mesh(args...; kws...) = plot_wireframe(args...; kws...)

function mesh(Z::AbstractMatrix; kws...)
    plot_wireframe([1:size(Z,1);]*ones(1,size(Z,2)),
                   ones(size(Z,1))*[1:size(Z,2);]', Z; kws...)
end

###########################################################################
# Allow plots with 2 independent variables (contour, surf, ...)
# to accept either 2 1d arrays or a row vector and a 1d array,
# to simplify construction of such plots via broadcasting operations.
# (Matplotlib is inconsistent about this.)

for f in (:contour, :contourf)
    @eval function $f(X::AbstractMatrix, Y::AbstractVector, args...; kws...)
        if size(X,1) == 1 || size(X,2) == 1
            $f(reshape(X, length(X)), Y, args...; kws...)
        elseif size(X,1) > 1 && size(X,2) > 1 && isempty(args)
            $f(X; levels=Y, kws...) # treat Y as contour levels
        else
            throw(ArgumentError("if 2nd arg is column vector, 1st arg must be row or column vector"))
        end
    end
end

for f in (:surf,:mesh,:plot_surface,:plot_wireframe,:contour3D,:contourf3D)
    @eval begin
        function $f(X::AbstractVector, Y::AbstractVector, Z::AbstractMatrix, args...; kws...)
            m, n = length(X), length(Y)
            $f(repmat(reshape(X,1,m),n,1), repmat(Y,1,m), Z, args...; kws...)
        end
        function $f(X::AbstractMatrix, Y::AbstractVector, Z::AbstractMatrix, args...; kws...)
            if size(X,1) != 1 && size(X,2) != 1
                throw(ArgumentError("if 2nd arg is column vector, 1st arg must be row or column vector"))
            end
            m, n = length(X), length(Y)
            $f(repmat(reshape(X,1,m),n,1), repmat(Y,1,m), Z, args...; kws...)
        end
    end
end

# Already work: barbs, pcolor, pcolormesh, quiver

# Matplotlib pcolor* functions accept 1d arrays but not ranges
for f in (:pcolor, :pcolormesh)
    @eval begin
        $f(X::Range, Y::Range, args...; kws...) = $f([X...], [Y...], args...; kws...)
        $f(X::Range, Y::AbstractArray, args...; kws...) = $f([X...], Y, args...; kws...)
        $f(X::AbstractArray, Y::Range, args...; kws...) = $f(X, [Y...], args...; kws...)
    end
end

###########################################################################
# a more pure functional style, that returns the figure but does *not*
# have any display side-effects.  Mainly for use with @manipulate (Interact.jl)

function withfig(actions::Function, f::Figure; clear=true)
    ax_save = gca()
    push!(withfig_fignums, f[:number])
    figure(f[:number])
    finalizer(f, close)
    try
        if clear && !isempty(f)
            clf()
        end
        actions()
    catch
        rethrow()
    finally
        try
            sca(ax_save) # may fail if axes were overwritten
        end
        Main.IJulia.undisplay(f)
    end
    return f
end

###########################################################################

using LaTeXStrings
export LaTeXString, latexstring, @L_str, @L_mstr

end # module PyPlot
