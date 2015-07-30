VERSION >= v"0.4.0-dev+6521" && __precompile__()

module ProfileView

using Colors
using Compat
if VERSION < v"0.4.0-dev+3275"
    using Base.Graphics
else
    using Graphics
end


if isdefined(Main, :PROFILEVIEW_USEGTK)
    useGtk = Main.PROFILEVIEW_USEGTK
else
    useGtk = !isdefined(Main, :IJulia)
end
if useGtk
    using Gtk.ShortNames, GtkUtilities
    import Cairo
    type ZoomCanvas
        bb::BoundingBox  # in user-coordinates
        c::Canvas
    end
end
include("svgwriter.jl")

import Base: contains, isequal, show, mimewritable, writemime

if VERSION < v"0.4.0-dev+980"
    builddict(a, b) = Dict(a,b)
else
    builddict(a, b) = Dict(zip(a,b))
end
include("tree.jl")
include("pvtree.jl")

using .Tree
using .PVTree

immutable TagData
    ip::Uint
    status::Int
end
const TAGNONE = TagData(@compat(UInt(0)), -1)

type ProfileData
    img
    lidict
    imgtags
    fontsize
end

const bkg = colorant"black"
const fontcolor = colorant"white"
const gccolor = colorant"red"
const colors = distinguishable_colors(13, [bkg,fontcolor,gccolor])[4:end]

function prepare(data; C = false, lidict = nothing, colorgc = true, combine = true)
    bt, counts = Profile.tree_aggregate(data)
    if isempty(counts)
        Profile.warning_empty()
        error("Nothing to view")
    end
    len = Int[length(x) for x in bt]
    keep = len .> 0
    if length(data) == Profile.maxlen_data()
        keep[end] = false
    end
    bt = bt[keep]
    counts = counts[keep]
    # Tk has trouble with very large images. If needed, pretend we took fewer samples.
    ncounts = sum(counts)
    if ncounts > 10^4
        counts = [floor(Int, c/(ncounts/10^4)) for c in counts]  # uniformly reduce the number of backtraces
        keep = counts .> 0
        counts = counts[keep]
        bt = bt[keep]
        if isempty(counts)
            error("No backtraces survived pruning.")
        end
    end
    # Do code address lookups on all unique instruction pointers
    uip = unique(vcat(bt...))
    nuip = length(uip)
    if lidict == nothing
        lkup = [Profile.lookup(ip) for ip in uip]
        lidict = builddict(uip, lkup)
    else
        lkup = [lidict[ip] for ip in uip]
    end
    isjl = builddict(uip, [!lkup[i].fromC for i = 1:nuip])
    isgc = builddict(uip, [lkup[i].func == "jl_gc_collect" for i = 1:nuip])
    isjl[@compat(UInt(0))] = false  # needed for root below
    isgc[@compat(UInt(0))] = false
    p = Profile.liperm(lkup)
    rank = similar(p)
    rank[p] = 1:length(p)
    ip2so = builddict(uip, rank)
    so2ip = builddict(rank, uip)
    # Build the graph
    level = 0
    w = sum(counts)
    root = Tree.Node(PVData(1:w))
    PVTree.buildgraph!(root, bt, counts, 0, ip2so, so2ip, lidict)
    PVTree.setstatus!(root, isgc)
#     Tree.showedges(STDOUT, root, x -> string(get(lidict, x.ip, "root"), ", hspan = ", x.hspan, ", status = ", x.status))
#     Tree.showedges(STDOUT, root, x -> string(get(lidict, x.ip, "root"), ", status = ", x.status))
#     Tree.showedges(STDOUT, root, x -> x.status == 0 ? nothing : string(get(lidict, x.ip, "root"), ", status = ", x.status))
#     checkidentity(ip2so, so2ip)
#     checkcontains(root, ip2so, so2ip, lidict)
#     checkstatus(root, isgc, isjl, C, lidict)
    counts = zeros(Int, length(uip))
    if !C
        PVTree.prunegraph!(root, isjl, lidict, ip2so, counts)
    end
#     for ip in uip
#         println(counts[ip2so[ip]], ": ", lidict[ip])
#     end
#     if !C
#         havegc = any([isgc[ip] for ip in uip])
#         if havegc
#             @assert checkprunedgc(root, false)
#         end
#     end
#     println("\nPruned:")
#     Tree.showedges(STDOUT, root, x -> string(get(lidict, x.ip, "root"), ", status = ", x.status))
    # Generate a "tagged" image
    rowtags = Any[fill(TAGNONE, w)]
    buildtags!(rowtags, root, 1)
    imgtags = hcat(rowtags...)
    img = buildimg(imgtags, colors, bkg, gccolor, colorgc, combine, lidict)
    img, lidict, imgtags
end

if useGtk
    function view(data = Profile.fetch(); C = false, lidict = nothing, colorgc = true, fontsize = 12, combine = true)
        img, lidict, imgtags = prepare(data, C=C, lidict=lidict, colorgc=colorgc, combine=combine)
        img24 = Uint32[convert(Uint32, convert(RGB24, img[i,j])) for i = 1:size(img,1), j = size(img,2):-1:1]'
        surf = Cairo.CairoRGBSurface(img24)
        imw = size(img24,2)
        imh = size(img24,1)
        # Display in a window
        c = @Canvas()
        f = @Frame(c)
        win = @Window(f, "Profile")
        czoom = ZoomCanvas(BoundingBox(0, imw, 0, imh), c)
        c.mouse.button1press = (widget, event) -> begin
            if event.event_type == Gtk.GdkEventType.BUTTON_PRESS
                c.mouse.motion = (c, event) -> nothing
                rubberband_start(c, event.x, event.y, (c, bb) -> zoom_bb(czoom, bb))
            elseif event.event_type == Gtk.GdkEventType.DOUBLE_BUTTON_PRESS
                zoom_reset(czoom)
            end
        end
        lasttextbb = BoundingBox(1,0,1,0)
        imgbb = BoundingBox(0, imw, 0, imh)
        standard_motion = function (c, event)
            # Repair image from ovewritten text
            ctx = getgc(c)
            w = width(c)
            if width(lasttextbb) > 0
                h = height(c)
                winbb = BoundingBox(0, w, 0, h)
                set_coords(ctx, winbb, czoom.bb)
                rectangle(ctx, lasttextbb)
                set_source(ctx, surf)
                p = Cairo.get_source(ctx)
                Cairo.pattern_set_filter(p, Cairo.FILTER_NEAREST)
                fill(ctx)
            end
            # Write the info
            xd, yd = event.x, event.y
            xu, yu = device_to_user(ctx, xd, yd)
            tag = gettag(xu, yu)
            if tag != TAGNONE
                li = lidict[tag.ip]
                str = string(basename(li.file), ", ", li.func, ": line ", li.line)
                set_source(ctx, fontcolor)
                Cairo.set_font_face(ctx, "sans-serif $(fontsize)px")
                lasttextbb = deform(Cairo.text(ctx, xu, yu, str, halign = xd < w/3 ? "left" : xd < 2w/3 ? "center" : "right"), -2, 2, -2, 2)
            end
            reveal(c)
        end
        c.mouse.motion = standard_motion
        function zoom_bb(czoom::ZoomCanvas, bb::BoundingBox)
            czoom.bb = bb & imgbb
            redraw(czoom.c)
            reveal(czoom.c)
            c.mouse.motion = standard_motion
        end
        function zoom_reset(czoom::ZoomCanvas)
            czoom.bb = imgbb
            redraw(czoom.c)
            reveal(czoom.c)
            c.mouse.motion = standard_motion
        end
        function redraw(c)
            ctx = getgc(c)
            w = width(c)
            h = height(c)
            cbb = czoom.bb
            winbb = BoundingBox(0, w, 0, h)
            set_coords(ctx, winbb, cbb)
            rectangle(ctx, cbb)
            set_source(ctx, surf)
            p = Cairo.get_source(ctx)
            Cairo.pattern_set_filter(p, Cairo.FILTER_NEAREST)
            fill(ctx)
        end
        # From a given position, find the underlying tag
        function gettag(xu, yu)
            x = ceil(Int, xu)
            y = ceil(Int, yu)
            Y = size(imgtags, 2)
            x = max(1, min(x, size(imgtags, 1)))
            y = max(1, min(y, Y))
            imgtags[x,Y-y+1]
        end
        c.resize = function (_)
            redraw(c)
            reveal(c)
        end
        # Hover over a block and see the source line
        # Right-click prints the full path, function, and line to the console
        c.mouse.button3press = function (c, event)
            ctx = getgc(c)
            xd, yd = event.x, event.y
            xu, yu = device_to_user(ctx, xd, yd)
            tag = gettag(xu, yu)
            if tag != TAGNONE
                li = lidict[tag.ip]
                println(li.file, ", ", li.func, ": line ", li.line)
            end
        end
        showall(win)
        nothing
    end
else
    function view(data = Profile.fetch(); C = false, lidict = nothing, colorgc = true, fontsize = 12, combine = true)
        img, lidict, imgtags = prepare(data, C=C, lidict=lidict, colorgc=colorgc, combine=combine)
        ProfileData(img, lidict, imgtags, fontsize)
    end
end

function svgwrite(filename::String, data, lidict; C = false, colorgc = true, fontsize = 12, combine = true)
    img, lidict, imgtags = prepare(data, C=C, lidict=lidict, colorgc=colorgc, combine=combine)
    pd = ProfileData(img, lidict, imgtags, fontsize)
    open(filename, "w") do file
        writemime(file, "image/svg+xml", pd)
    end
    nothing
end
function svgwrite(filename::String; kwargs...)
    data, lidict = Profile.retrieve()
    svgwrite(filename, data, lidict; kwargs...)
end


mimewritable(::MIME"image/svg+xml", pd::ProfileData) = true

function writemime(f::IO, ::MIME"image/svg+xml", pd::ProfileData)

    img = pd.img
    lidict = pd.lidict
    imgtags = pd.imgtags
    fontsize = pd.fontsize

    ncols, nrows = size(img)
    leftmargin = rightmargin = 10
    width = 1200
    topmargin = 30
    botmargin = 40
    rowheight = 15
    height = ceil(rowheight*nrows + botmargin + topmargin)
    xstep = (width - (leftmargin + rightmargin)) / ncols
    ystep = (height - (topmargin + botmargin)) / nrows
    avgcharwidth = 6  # for Verdana 12 pt font
    function eschtml(str)
        s = replace(str, '<', "&lt;")
        s = replace(s, '>', "&gt;")
        s = replace(s, '&', "&amp;")
        s
    end
    function printrec(f, samples, xstart, xend, y, tag, rgb)
        width = xend - xstart
        li = lidict[tag.ip]
        info = "$(li.func) in $(li.file):$(li.line)"
        info = eschtml(info)
        shortinfo = info
        #if avgcharwidth*3 > width
        #    shortinfo = ""
        #elseif length(shortinfo) * avgcharwidth > width
        #    nchars = int(width/avgcharwidth)-2
        #    shortinfo = eschtml(info[1:nchars] * "..")
        #end
        red = round(Integer,255*rgb.r)
        green = round(Integer,255*rgb.g)
        blue = round(Integer,255*rgb.b)
        print(f, """<rect vector-effect="non-scaling-stroke" x="$xstart" y="$y" width="$width" height="$ystep" fill="rgb($red,$green,$blue)" rx="2" ry="2" data-shortinfo="$shortinfo" data-info="$info"/>\n""")
        #if shortinfo != ""
        println(f, """\n<text text-anchor="" x="$(xstart+4)" y="$(y+11.5)" font-size="12" font-family="Verdana" fill="rgb(0,0,0)" ></text>""")
        # end
    end

    fig_id = string("fig-", replace(string(Base.Random.uuid4()), "-", ""))
    svgheader(f, fig_id, width=width, height=height)
    # rectangles are on a grid and split across multiple columns (must span similar adjacent ones together)
    for r in 1:nrows
        # top of rectangle:
        y = height - r*ystep - botmargin
        # local vars:
        prevtag = TAGNONE
        xstart = xend = 0.0
        for c in 1:ncols
            tag = imgtags[c,r]
            if prevtag == TAGNONE && prevtag != tag
                # Very first in span
                xstart = (c-1) * xstep + leftmargin
            elseif tag != prevtag && tag != TAGNONE && prevtag != TAGNONE
                # End of old span and start of new one
                xend = (c-1) * xstep + leftmargin
                samples = int(round((xend - xstart)/xstep))
                printrec(f, samples, xstart, xend, y, prevtag, img[c-1,r])
                xstart = xend
            elseif tag == TAGNONE && tag != prevtag
                # at end of span and start of nothing
                xend = (c-1) * xstep + leftmargin
                samples = int(round((xend - xstart)/xstep))
                printrec(f, samples, xstart, xend, y, prevtag, img[c-1,r])
                xstart = 0.0
            elseif c == ncols && tag != TAGNONE
                # end of span at last element of row
                xend = (c-1) * xstep + leftmargin
                samples = round(Int,(xend - xstart)/xstep)
                printrec(f, samples, xstart, xend, y, tag, img[c,r])
                xstart = 0.0
            else
                # in middle of span
            end
            prevtag = tag
        end
    end
    svgfinish(f, fig_id)
end

function buildtags!(rowtags, parent, level)
    if isleaf(parent)
        return
    end
    w = length(rowtags[1])
    if length(rowtags) < level
        push!(rowtags, fill(TAGNONE, w))
    end
    t = rowtags[level]
    for c in parent
        t[c.data.hspan] = TagData(c.data.ip, c.data.status)
        buildtags!(rowtags, c, level+1)
    end
end

function buildimg(imgtags, colors, bkg, gccolor, colorgc::Bool, combine::Bool, lidict)
    w = size(imgtags,1)
    h = size(imgtags,2)
    img = fill(bkg, w, h)
    colorlen = round(Int, length(colors)/2)
    for j = 1:h
        coloroffset = colorlen*iseven(j)
        colorindex = 1
        lasttag = TAGNONE
        status = 0
        first = 0
        nextcolor = colors[coloroffset + colorindex]
        for i = 1:w
            t = imgtags[i,j]
            if t != TAGNONE
                if t != lasttag && (lasttag == TAGNONE || !(combine && lidict[lasttag.ip] == lidict[t.ip]))
                    if first != 0
                        colorindex = fillrow!(img, j, first:i-1, colorindex, colorlen, nextcolor, gccolor, status & colorgc)
                        nextcolor = colors[coloroffset + colorindex]
                        status = t.status
                    end
                    first = i
                    lasttag = t
                else
                    status |= t.status
                end
            else
                if first != 0
                    # We transitioned from tag->none, render the previous range
                    colorindex = fillrow!(img, j, first:i-1, colorindex, colorlen, nextcolor, gccolor, status & colorgc)
                    nextcolor = colors[coloroffset + colorindex]
                    first = 0
                    lasttag = TAGNONE
                end
            end
        end
        if first != 0
            # We got to the end of a row, render the previous range
            fillrow!(img, j, first:w, colorindex, colorlen, nextcolor, gccolor, status & colorgc)
        end
    end
    img
end

function fillrow!(img, j, rng::UnitRange{Int}, colorindex, colorlen, regcolor, gccolor, status)
    if status > 0
        img[rng,j] = gccolor
        return colorindex
    else
        img[rng,j] = regcolor
        return mod1(colorindex+1, colorlen)
    end
end

#### Debugging code

function checkidentity(ip2so, so2ip)
    for (k,v) in ip2so
        @assert so2ip[v] == k
    end
end

function checkcontains(root, ip2so, so2ip, lidict)
    flag = contains(root, ip2so)
    if !all(flag)
        missing = find(!flag)
        println("missing ips:")
        for i in missing
            @show i
            @show so2ip[i]
            println(lidict[so2ip[i]])
        end
        error("Internal error: the tree does not contain all ips")
    end
end

# This skips the parent, gets everything else
# (to avoid a problem with root with ip=0)
function contains(parent::Node, ip2so::Dict)
    ret = Array(Bool, 0)
    contains!(ret, parent, ip2so)
    @show length(ip2so)
    @show length(ret)
    return ret
end

function contains!(ret, parent::Node, ip2so::Dict)
    for c in parent
        indx = ip2so[c.data.ip]
        setindexsafe!(ret, indx, true)
        contains!(ret, c, ip2so)
    end
end

function setindexsafe!(a, i::Integer, val)
    if i > length(a)
        insert!(a, i, val)
    else
        a[i] = val
    end
end

function checkstatus(parent::Node, isgc::Dict, isjl::Dict, C, lidict)
    if isgc[parent.data.ip] && parent.data.status == 0
            @show lidict[parent.data.ip]
            error("gc should be set, and it isn't")
    end
    for c in parent
        checkstatus(c, isgc, isjl, C, lidict)
    end
end

function checkprunedgc(parent::Node, tf::Bool)
    tf |= parent.data.status > 0
    if !tf
        for c in parent
            tf = checkprunedgc(c, tf)
        end
    end
    tf
end

end
