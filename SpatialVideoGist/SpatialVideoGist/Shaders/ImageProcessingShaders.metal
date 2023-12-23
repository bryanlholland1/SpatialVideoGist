//
//  VideoHelpers.metal
//  SpatialVideoGist
//
//  Created by Bryan on 12/18/23.
//

#include <metal_stdlib>
using namespace metal;

kernel void sideBySideEffect(
    texture2d<float, access::read> inputTextureA [[texture(0)]],
    texture2d<float, access::read> inputTextureB [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint outputWidth = inputTextureA.get_width();
    
    float4 inputColorLeft = inputTextureA.read(gid);
    float4 inputColorRight = inputTextureB.read(gid);

    outputTexture.write(inputColorLeft, gid);
    
    uint2 gidB = uint2(gid.x + outputWidth, gid.y);
    outputTexture.write(inputColorRight, gidB);
}
