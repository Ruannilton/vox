#define VOXEL_GRID_SIZE 16
#define VOXEL_GRID_VOLUME (VOXEL_GRID_SIZE * VOXEL_GRID_SIZE * VOXEL_GRID_SIZE)

struct GlobalConstants {
    float4x4 mvp;
    float time;
};

struct Chunk
{
    uint voxels[VOXEL_GRID_VOLUME];
};

[[vk::push_constant]]
ConstantBuffer<GlobalConstants> globalConstants;