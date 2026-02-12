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
	live_projectiles = {
		enabled = true,
		line = { r = 255, g = 255, b = 255, a = 150 },
		marker = { r = 255, g = 255, b = 255, a = 255 },
		explosion_radius = 150,
		marker_size = 3,
		max_distance = 4000,
		rockets = true,
		stickies = true,
		pipes = true,
		flares = true,
		arrows = true,
		energy = true,
		fireballs = true,
		revalidate_angle = 45,
		revalidate_distance = 5,
	},
	outline = {
		line_and_flags = true,
		polygon = true,
		r = 0,
		g = 0,
		b = 0,
		a = 155,
	},
	accuracy = 75, -- percent
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
	sticky_base_speed = 900,
	sticky_max_speed = 2400,
	sticky_upward_vel = 200,
	sticky_gravity = 800,
}

Config.simulation = {
	downward_search_steps = 24,
	trace_interval = 2.5,
	lazy_collision_min_step = 0.03,
	lazy_collision_max_step = 0.15,
	lazy_collision_grow_factor = 1.5,
}

local function mapAccuracyToStep()
	local acc = math.max(10, math.min(100, Config.visual.accuracy))
	-- 100% accuracy = tick interval, 10% accuracy = 10x tick interval
	local multiplier = 100 / acc
	local tickInterval = globals.TickInterval() or 0.015 -- fallback to 66 tick
	return tickInterval * multiplier
end

function Config.recomputeComputed()
	local traceInterval = mapAccuracyToStep()
	Config.computed.trace_interval = traceInterval
	Config.computed.flag_interval = traceInterval * 1320
end

Config.computed = {
	trace_interval = 0,
	flag_interval = 0,
}
Config.recomputeComputed()

Config.IN_ATTACK = 1
Config.TRACE_MASK = MASK_SHOT_BRUSHONLY or 100679691

Config.PHYSICS_MODEL_PATHS = {
	[1] = "models/weapons/w_models/w_stickybomb.mdl",
	[2] = "models/workshop/weapons/c_models/c_kingmaker_sticky/w_kingmaker_stickybomb.mdl",
	[3] = "models/weapons/w_models/w_stickybomb_d.mdl",
}

return Config
