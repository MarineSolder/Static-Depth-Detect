// --------------------------------------------------------------------
//  Shader name:  Static Depth Detect
// --------------------------------------------------------------------
//  Version:      0.3a
//  Author:       MarineSolder © 2026
//  License:      Proprietary
//  Source:       https://github.com/MarineSolder/Static-Depth-Detect
// --------------------------------------------------------------------
// Technical Requirements & Limitations:
// - Disable MSAA in game settings for depth detection to work.
// - Generic Depth: Depth Addon must be enabled in ReShade's settings.
// - Buffer Polarity: The depth input must have the correct polarity
//   (RESADE_DEPTH_INPUT_IS_REVERSED) to track depth state changes.
// - Hardware Compatibility: Nvidia GTX 900 series or newer
//                           AMD RX 400 series or newer
//                           Intel HD Graphics 500 or newer
// --------------------------------------------------------------------

#include "ReShade.fxh"

// ------- UI -------

uniform int Info <
    ui_category = "Info";
    ui_label = " ";
    ui_type = "radio";
    ui_text = "Shader: Static Depth Detect v0.3a\n"
              "Author: MarineSolder © 2026\n\n"
              "In many legacy titles, the 3D scene completely freezes during Menu\n"
              "navigation or FMV playback. This shader tries to detect depth state and\n"
              "automatically toggles off/on scene effects (e.g., Bloom, AO, RT)\n"
              "to prevent interference with Menu or FMV.\n\n"
              "USAGE ORDER:\n"
              "1. StaticDepth_Detect -> Place at the VERY TOP.\n"
              "2. StaticDepth_Before -> Place BEFORE desired effects.\n"
              "3. StaticDepth_After  -> Place AFTER desired effects.\n\n";
> = 0;

uniform int PointsGrid <
    ui_type = "combo";
    ui_items = "Low (6x4)\0Medium (12x8)\0High (24x16)\0Extreme (60x40)\0";
    ui_category = "Detection Area"; 
    ui_label = "Density of Scan Points";
    ui_tooltip = "Different density for different gameplay situations. Low - minimal GPU usage, high - a bit more GPU usage.";
> = 1;

uniform int SensFrames <
    ui_type = "slider"; ui_min = 10; ui_max = 300; ui_step = 1;
    ui_category = "Detection Area"; 
    ui_label = "Number of frames";
    ui_tooltip = "How many frames the Depth Buffer must remain static to Trigger.";
> = 30;

uniform int SensLevel <
    ui_type = "slider"; ui_min = 1; ui_max = 5;
    ui_category = "Adjustment"; 
    ui_label = "Sensitivity Level";
    ui_tooltip = "Multiplier for global Sensitivity Level. Low - more lazy detection, high - more aggressive detection.";
> = 4;

uniform int DelayFrames <
    ui_type = "slider"; ui_min = 0; ui_max = 100; ui_step = 1;
    ui_category = "Adjustment"; 
    ui_label = "Visual Delay (frames)";
    ui_tooltip = "Additional frames to wait before Trigger. Use it to control flickering of the mask.";
> = 5;

uniform int ReleaseSpeed <
    ui_type = "slider"; ui_min = 1; ui_max = 10; ui_step = 1;
    ui_category = "Adjustment"; 
    ui_label = "Release Decay";
    ui_tooltip = "Decay speed of the Trigger. Lower - slower Decay speed, higher - faster Decay speed.";
> = 5;

uniform bool ShowDebugTint < 
    ui_category = "Debug"; 
    ui_label = "Show Trigger Overlay (Red Tint)"; 
> = true;

uniform bool ShowScanPoints < 
    ui_category = "Debug"; 
    ui_label = "Show Scan Points (Yellow Dots)"; 
> = true;

// ------- HELPERS -------

#define MAX_PTS (PointsGrid == 0 ? 24 : (PointsGrid == 1 ? 96 : (PointsGrid == 2 ? 384 : 2400)))
#define MAX_WIDTH 2400

static const float GridColsTable[4] = { 6.0f, 12.0f, 24.0f, 60.0f };
static const float GridRowsTable[4] = { 4.0f, 8.0f, 16.0f, 40.0f };

static const float BoostTable[5] = { 1.0f, 10.0f, 100.0f, 1000.0f, 10000.0f };

float2 GetScanPoint(const uint i, const int mode)
{
    const int gridIndex = clamp(mode, 0, 3);

    const float gridCols = GridColsTable[gridIndex];
    const float colIntervals = gridCols - 1.0f;
    const float rowIntervals = GridRowsTable[gridIndex] - 1.0f;
    const float fI = (float)i + 0.0001f;

    const float row = floor(fI / gridCols);
    const float col = floor(fI - (row * gridCols));

    return float2(0.05f + (col / colIntervals) * 0.90f, 0.05f + (row / rowIntervals) * 0.90f);
}

// ------- STORAGE -------

texture MS_CleanTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler MS_CleanSampler { Texture = MS_CleanTex; };

texture MS_StateA { Width = 1; Height = 1; Format = RGBA32F; };
texture MS_StateB { Width = 1; Height = 1; Format = RGBA32F; };
sampler MS_StateSamplerA { Texture = MS_StateA; };
sampler MS_StateSamplerB { Texture = MS_StateB; };

texture MS_PointsPrev { Width = MAX_WIDTH; Height = 1; Format = R32F; };
sampler MS_PointsSampler { Texture = MS_PointsPrev; };

// ------- SHADERS -------

void PS_Detection(float4 pos : SV_Position, float2 uv : TEXCOORD, out float4 outStateB : SV_Target)
{
    const float4 lastState = tex2Dfetch(MS_StateSamplerA, int4(0, 0, 0, 0));
    float deltaDepth = 0.0f;

    const float boost = BoostTable[clamp(SensLevel - 1, 0, 4)];

    const float sens_static = 0.0001f;
    const float sens_active  = 0.0002f;

    const bool isStatic = (lastState.a > 0.5f);
    const float currentSens = isStatic ? sens_active : sens_static;

    [loop]
    for (uint i = 0; i < MAX_PTS; i++)
    {
        const float2 pointPos = GetScanPoint(i, PointsGrid);

        const float depthCurrent = (float)ReShade::GetLinearizedDepth(pointPos);
        const float depthPrevious = (float)tex2Dfetch(MS_PointsSampler, int4(i, 0, 0, 0)).r;
        const float depthDiff = abs(depthCurrent - depthPrevious) * boost;

        if (depthDiff > currentSens)
        {
            deltaDepth = depthDiff;
            break;
        }
        deltaDepth = max(deltaDepth, depthDiff);
    }

    float staticCounter = lastState.g;
    const float maxCounter = (float)SensFrames + (float)DelayFrames;

    if (deltaDepth < currentSens) 
    {
        staticCounter = min(staticCounter + 1.0f, maxCounter);
    }
    else
    {
        staticCounter = max(staticCounter - (float)ReleaseSpeed, 0.0f);
    }

    float triggerState = lastState.a;
    if (staticCounter >= maxCounter) triggerState = 1.0f;

    else if (staticCounter <= (float)DelayFrames) triggerState = 0.0f;

    outStateB = float4(0.0f, staticCounter, deltaDepth, triggerState);
}

void PS_Sync(float4 pos : SV_Position, float2 uv : TEXCOORD, out float4 outStateA : SV_Target)
{
    outStateA = tex2Dfetch(MS_StateSamplerB, int4(0, 0, 0, 0));
}

void PS_StorePoints(float4 pos : SV_Position, float2 uv : TEXCOORD, out float4 outPoint : SV_Target)
{
    const uint i = (uint)pos.x;

    if (i < (uint)MAX_PTS)
    {
        outPoint = float4((float)ReShade::GetLinearizedDepth(GetScanPoint(i, PointsGrid)), 0.0f, 0.0f, 0.0f);
    }
    else
    {
        discard;
    }
}

void PS_Capture(float4 pos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target)
{
    outColor = tex2D(ReShade::BackBuffer, uv);
}

void PS_Toggle(float4 pos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target)
{
    const float4 state = tex2Dfetch(MS_StateSamplerB, int4(0, 0, 0, 0));
    const bool isStatic = (state.a > 0.5f);

    if (isStatic)
    {
        outColor = tex2D(MS_CleanSampler, uv);

        if (ShowDebugTint)
        outColor.rgb = lerp(outColor.rgb, float3(1.0f, 0.0f, 0.0f), 0.2f);
    }
    else
    {
        outColor = tex2D(ReShade::BackBuffer, uv);
    }

        if (ShowScanPoints)
    {
        const int gridIndex = clamp(PointsGrid, 0, 3);
        const float2 intervals = float2(GridColsTable[gridIndex] - 1.0f, GridRowsTable[gridIndex] - 1.0f);
        const float2 screenRes = float2(BUFFER_WIDTH, BUFFER_HEIGHT);

        float2 nearestIdx = round(((uv - 0.05f) / 0.90f) * intervals);
        nearestIdx = clamp(nearestIdx, 0.0f, intervals);
        const float2 targetUV = 0.05f + (nearestIdx / intervals) * 0.90f;

        const float2 distPixels = abs(uv - targetUV) * screenRes;
        if (distPixels.x < 2.0f && distPixels.y < 2.0f) 
        {
            outColor.rgb = float3(1.0f, 1.0f, 0.0f);
        }
    }
}

// ------- TECHNIQUES -------

technique StaticDepth_Detect
{
    pass { VertexShader = PostProcessVS; PixelShader = PS_Detection; RenderTarget = MS_StateB; }
    pass { VertexShader = PostProcessVS; PixelShader = PS_Sync; RenderTarget = MS_StateA; }
    pass { VertexShader = PostProcessVS; PixelShader = PS_StorePoints; RenderTarget = MS_PointsPrev; }
}

technique StaticDepth_Before
{
    pass { VertexShader = PostProcessVS; PixelShader = PS_Capture; RenderTarget = MS_CleanTex; }
}

technique StaticDepth_After
{
    pass { VertexShader = PostProcessVS; PixelShader = PS_Toggle; }
}
