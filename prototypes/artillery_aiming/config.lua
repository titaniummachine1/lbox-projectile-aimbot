local Config = {}

Config.visual = {
	polygon = {
		enabled = true,
		r = 255,
		g = 200,
		b = 155,
		a = 25,
		size = 10,
		segments = 20,
	},
	line = {
		enabled = true,
		r = 255,
		g = 255,
		b = 255,
		a = 255,
	},
	flags = {
		enabled = true,
		r = 255,
		g = 0,
		b = 0,
		a = 255,
		size = 5,
	},
	outline = {
		line_and_flags = true,
		polygon = true,
		r = 0,
		g = 0,
		b = 0,
		a = 155,
	},
	measure_segment_size = 2.5,
}

Config.camera = {
	width = 650,
	height = 400,
	x = 25,
	y = 300,
	scrollStep = 0.01,
	interpSpeed = 0.15,
	fov = 90,
}

Config.keybinds = {
	activate = KEY_F,
	activate_mode = "hold",
	high_ground = KEY_Q,
	high_ground_mode = "hold",
	scroll_mode_toggle = KEY_V,
}

Config.bombard = {
	enabled = true,
	min_distance = 10,
	max_distance = 5000,
	distance_step = 50,
	sensitivity = 0.50,
	downward_surface_threshold = 0.707,
}

Config.physics = {
	default_gravity = 800,
}

Config.simulation = {
	downward_search_steps = 24,
	trace_interval = 2.5,
	lazy_collision_min_step = 0.03,
	lazy_collision_max_step = 0.15,
	lazy_collision_grow_factor = 1.5,
}

local traceInterval = math.max(0.5, math.min(8, Config.visual.measure_segment_size)) / 66
Config.computed = {
	trace_interval = traceInterval,
	flag_interval = traceInterval * 1320,
}

Config.IN_ATTACK = 1
Config.TRACE_MASK = 100679691

Config.PHYSICS_MODEL_PATHS = {
	[1] = "models/weapons/w_models/w_stickybomb.mdl",
	[2] = "models/workshop/weapons/c_models/c_kingmaker_sticky/w_kingmaker_stickybomb.mdl",
	[3] = "models/weapons/w_models/w_stickybomb_d.mdl",
}

return Config
