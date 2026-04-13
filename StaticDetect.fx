/*
    Static Depth Detect (Ultra Precision)
    Version 0.1a (Batman: Arkham Asylum version)
    Author: MarineSolder © 2026
    Source: https://github.com/MarineSolder/Static-Depth-Detect
*/

#include "ReShade.fxh"

// --- UI ---

uniform int FrameThreshold <
    ui_type = "slider"; ui_min = 10; ui_max = 500;
    ui_label = "Detection: Number of frames";
> = 30;

uniform bool ShowDebugStatus < ui_label = "Show Trigger Overlay (Red Tint)"; > = true;
uniform bool ShowScanPoints < ui_label = "Show Scan Points (Yellow Dots)"; > = true;

// --- Storage ---

texture MS_StateTex { Width = 1; Height = 1; Format = RGBA32F; };
sampler MS_StateSampler { Texture = MS_StateTex; };

texture MS_BeforeTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler MS_BeforeSampler { Texture = MS_BeforeTex; };

// --- Helpers ---

float2 GetScanPoint(int i)
{
    if (i < 20)
    {
        float offset = 0.1 + (float(i % 5)) * 0.2;
        int side = i / 5;
        if (side == 0) return float2(offset, 0.1);
        if (side == 1) return float2(offset, 0.9);
        if (side == 2) return float2(0.1, offset);
        return               float2(0.9, offset);
    }
    
    int center_i = i - 20;
    
    if (center_i == 0) return float2(0.25, 0.3);
    if (center_i == 1) return float2(0.25, 0.5);
    if (center_i == 2) return float2(0.25, 0.7);
    
    if (center_i == 3) return float2(0.75, 0.3);
    if (center_i == 4) return float2(0.75, 0.5);
    return               float2(0.75, 0.7);
}

// --- Shaders ---

float4 PS_UpdateDetection(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float currentDepthSum = 0.0;
    
    [unroll]
    for (int i = 0; i < 26; i++)
    {
        currentDepthSum += ReShade::GetLinearizedDepth(GetScanPoint(i)) * 1000.0;
    }

    float4 s_old = tex2D(MS_StateSampler, float2(0.5, 0.5));
    float f_accum = s_old.g;
    float diff = abs(currentDepthSum - s_old.r);

    bool is_static = diff < 0.000005; 
    bool is_moving = diff > 0.000007; 

    if (is_static)
    {
        f_accum = min(f_accum + 1.0, (float)FrameThreshold + 10.0);
    }
    else if (is_moving)
    {
        f_accum = 0.0;
    }

    float is_vid = (f_accum >= (float)FrameThreshold) ? 1.0 : 0.0;

    return float4(currentDepthSum, f_accum, 0.0, is_vid);
}

float4 PS_SaveFrame(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    return tex2D(ReShade::BackBuffer, texcoord);
}

float4 PS_ApplyMask(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float3 effectColor = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float3 cleanColor = tex2D(MS_BeforeSampler, texcoord).rgb;
    float4 state = tex2D(MS_StateSampler, float2(0.5, 0.5));
    float isVideo = state.a;

    float3 finalColor = (isVideo > 0.5) ? cleanColor : effectColor;

    if (ShowDebugStatus && isVideo > 0.5)
        finalColor = lerp(finalColor, float3(1.0, 0.0, 0.0), 0.2);

    if (ShowScanPoints)
    {
        [unroll]
        for (int k = 0; k < 26; k++)
        {
            float2 p = GetScanPoint(k);
            float2 dist = abs(texcoord - p) * float2(BUFFER_WIDTH, BUFFER_HEIGHT);
            if (dist.x < 2.0 && dist.y < 2.0) finalColor = float3(1.0, 1.0, 0.0);
        }
    }

    return float4(finalColor, 1.0);
}

// --- Techniques ---

technique StaticDepth_Detect {
    pass { VertexShader = PostProcessVS; PixelShader = PS_UpdateDetection; RenderTarget = MS_StateTex; }
}

technique StaticDepth_Before {
    pass { VertexShader = PostProcessVS; PixelShader = PS_SaveFrame; RenderTarget = MS_BeforeTex; }
}

technique StaticDepth_After {
    pass { VertexShader = PostProcessVS; PixelShader = PS_ApplyMask; }
}