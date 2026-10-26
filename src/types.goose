namespace ft;
import vec;

struct Vertex { pos: float3, normal: float3, color: float4 }

fn splat(n: f32) -> float3 {
    float3 { n, n, n }
}

fn rgb(r: f32, g: f32, b: f32) -> float4 {
    float4 { r, g, b, 1.0 }
}
