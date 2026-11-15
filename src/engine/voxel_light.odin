package engine


LIGHT_RELIGHT_NEIGHBORS :: [27]ChunkCoordinate{
	{0, 0, 0},
	{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
	{1, 1, 0}, {1, -1, 0}, {-1, 1, 0}, {-1, -1, 0},
	{1, 0, 1}, {1, 0, -1}, {-1, 0, 1}, {-1, 0, -1}, {0, 1, 1}, {0, 1, -1}, {0, -1, 1}, {0, -1, -1},
	{1, 1, 1}, {1, 1, -1}, {1, -1, 1}, {1, -1, -1},
	{-1, 1, 1}, {-1, 1, -1}, {-1, -1, 1}, {-1, -1, -1},
}

light_manager_init :: proc(ve: ^VoxelEngine) {
	ve.light_dirty = make(map[ChunkCoordinate]struct{})
	ve.light_job_counts = [MAX_FRAMES_IN_FLIGHT]u32{}
	// Sentinela: força a primeira recentralização a reescrever o grid inteiro.
	ve.light_grid_min = ChunkCoordinate{max(i32), max(i32), max(i32)}
}

light_manager_destroy :: proc(ve: ^VoxelEngine) {
	delete(ve.light_dirty)
}

@(private)
light_grid_cell_index :: proc "contextless" (grid_min: ChunkCoordinate, coord: ChunkCoordinate) -> (u32, bool) {
	rel := coord - grid_min
	if rel.x < 0 || rel.y < 0 || rel.z < 0 ||
	   rel.x >= LIGHT_GRID_DIM_X || rel.y >= LIGHT_GRID_DIM_Y || rel.z >= LIGHT_GRID_DIM_Z {
		return 0, false
	}
	dx := u32(LIGHT_GRID_DIM_X)
	dz := u32(LIGHT_GRID_DIM_Z)
	return u32(rel.x) + dx * (u32(rel.z) + dz * u32(rel.y)), true
}

@(private)
light_grid_publish :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate, slot: u32) {
	index, ok := light_grid_cell_index(ve.light_grid_min, coord)
	if !ok do return
	voxel_gpu.chunk_grid_mapped[index] = slot
}

@(private)
light_service_grid :: proc(ve: ^VoxelEngine, camera_chunk: ChunkCoordinate) {
	grid_min := ChunkCoordinate{
		camera_chunk.x - LIGHT_GRID_DIM_X / 2,
		camera_chunk.y - LIGHT_GRID_DIM_Y / 2,
		camera_chunk.z - LIGHT_GRID_DIM_Z / 2,
	}
	if grid_min == ve.light_grid_min do return
	ve.light_grid_min = grid_min
	{
		ZoneN("light.grid_recenter")
		for i in 0 ..< LIGHT_GRID_CELL_COUNT {
			voxel_gpu.chunk_grid_mapped[i] = NEIGHBOR_SLOT_INVALID
		}
		for coord, record in ve.active_chunks {
			if record.state == .CACHED || record.state == .RENDERABLE {
				light_grid_publish(ve, coord, record.storage_slot_index)
			}
		}
	}
}

light_mark_dirty :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate) {
	ve.light_dirty[coord] = {}
}

light_build_jobs :: proc(ve: ^VoxelEngine, frame_index: u32) -> u32 {
	ZoneN("light.jobs_build")
	frame_idx := int(frame_index % config.frames_in_flight)
	count: u32 = 0
	selected := make(map[ChunkCoordinate]struct{}, context.temp_allocator)
	for dirty in ve.light_dirty {
		if count >= MAX_LIGHT_JOBS_PER_FLUSH do break
		for offset in LIGHT_RELIGHT_NEIGHBORS {
			if count >= MAX_LIGHT_JOBS_PER_FLUSH do break
			coord := dirty + offset
			if coord in selected do continue
			record, found := ve.active_chunks[coord]
			if !found do continue
			if record.state != .CACHED && record.state != .RENDERABLE do continue
			selected[coord] = {}
			voxel_gpu.light_jobs_mapped[frame_idx * MAX_LIGHT_JOBS_PER_FLUSH + int(count)] = LightJob{
				chunk_world_origin = coord * CHUNK_SIZE,
				storage_slot_index = record.storage_slot_index,
			}
			count += 1
		}
		delete_key(&ve.light_dirty, dirty)
	}
	ve.light_job_counts[frame_idx] = count
	return count
}


light_update_globals :: proc(
	ve: ^VoxelEngine,
	frame_index: u32,
	camera_position: [3]f32,
	debug_mode: u32,
	torch_enabled: bool,
) {
	ZoneN("light.globals_update")
	frame_idx := int(frame_index % config.frames_in_flight)
	globals := LightGlobals{
		sun_direction = LIGHT_SUN_DIRECTION,
		sun_color = LIGHT_SUN_COLOR,
		sky_zenith = LIGHT_SKY_ZENITH,
		sky_horizon = LIGHT_SKY_HORIZON,
		grid_min_chunk = {ve.light_grid_min.x, ve.light_grid_min.y, ve.light_grid_min.z, 0},
		grid_dim_chunks = {LIGHT_GRID_DIM_X, LIGHT_GRID_DIM_Y, LIGHT_GRID_DIM_Z, 0},
		params = {LIGHT_SHADOW_MAX_DISTANCE, LIGHT_AO_STRENGTH, LIGHT_BLOCK_LIGHT_STRENGTH, 0},
		counts = {0, debug_mode, 0, 0},
	}
	if torch_enabled {
		globals.counts[0] = 1
		globals.dynamic_light_position_radius[0] = {
			camera_position.x, camera_position.y - 0.25, camera_position.z, LIGHT_TORCH_RADIUS,
		}
		globals.dynamic_light_color[0] = LIGHT_TORCH_COLOR
	}
	slot := voxel_gpu.light_globals_ubo_mapped[frame_idx * int(voxel_gpu.light_globals_alignment):]
	(cast(^LightGlobals)&slot[0])^ = globals
}

// Directional fixa (values iniciais sugeridos pela referência de design).
LIGHT_SUN_DIRECTION :: [4]f32{0.5016, 0.8025, 0.3010, 0} // normalize(0.5, 0.8, 0.3)
LIGHT_SUN_COLOR :: [4]f32{1.0, 0.98, 0.92, 0}
LIGHT_SKY_ZENITH :: [4]f32{0.35, 0.5, 0.8, 0}
LIGHT_SKY_HORIZON :: [4]f32{0.22, 0.22, 0.24, 0}
LIGHT_SHADOW_MAX_DISTANCE :: f32(128)
LIGHT_AO_STRENGTH :: f32(1.0)
LIGHT_BLOCK_LIGHT_STRENGTH :: f32(1.0)
LIGHT_TORCH_RADIUS :: f32(14)
LIGHT_TORCH_COLOR :: [4]f32{1.0, 0.75, 0.45, 0}
