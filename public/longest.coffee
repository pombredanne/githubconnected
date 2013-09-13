if `!window.console || typeof(window.console) === 'undefined'`
	window.console = {}
	window.console.log = window.console.error = window.console.info = window.console.debug = window.console.warn = window.console.trace = window.console.dir = window.console.dirxml = window.console.group = window.console.groupEnd = window.console.time = window.console.timeEnd = window.console.assert = window.console.profile = ->
		# do nothing

width = 1170
height = 800

color = d3.scale.category10();

layout = d3.layout.force()
	.size([width, height])
	.charge(-300)
	.linkDistance(100)

svg = d3.select("#graph-container")
	.append("svg")
	.attr("width", width)
	.attr("height", height)
	.append('svg:g')
	.attr("pointer-events", "all")
	.append('svg:g')

svg.append('svg:rect')
	.attr('width', width)
	.attr('height', height)
	.attr('fill', 'white');


svg.call d3.behavior.drag().on "drag", ->
	svg.attr "transform", "translate(" + d3.event.translate + ")"

svg.call d3.behavior.zoom().on "zoom", ->
	svg.attr "transform", "translate(" + d3.event.translate + ") scale(" + d3.event.scale + ")"

d3.json 'longest.json', (error, graph) ->

	d3.select('#graph-loading').remove();

	layout.nodes(graph.nodes)
		.links(graph.links)
		.start()

	link = svg.selectAll(".link")
		.data(graph.links)
		.enter()
		.append("line")
		.attr("class", "link")

	node = svg.selectAll("node")
		.data(graph.nodes)
		.enter()
		.append("g")
		.attr("class", "node")
		.style "fill", (d) ->
			color(d.group);
		.call(layout.drag)

	node.append("image")
		.attr("xlink:href", "https://github.com/favicon.ico")
		.attr("x", -8)
		.attr("y", -8)
		.attr("width", 16)
		.attr("height", 16);

	node.append("text")
		.attr("dx", 0)
		.attr("dy", 0)
		.text (d) ->
			d.name

	layout.on "tick", ->

		link.attr "x1", (d) ->
			d.source.x
		.attr "y1", (d) ->
			d.source.y
		.attr "x2", (d) ->
			d.target.x
		.attr "y2", (d) ->
			d.target.y

		node.attr "transform", (d) ->
			"translate(" + d.x + "," + d.y + ")"

		[link, node]

	graph