// -----------------------------------------------------------------------------
//  Shader name:  Static Depth Detect
// -----------------------------------------------------------------------------
//  Version:      0.5a
//  Author:       MarineSolder © 2026
//  License:      Proprietary
//  Source:       https://github.com/MarineSolder/Static-Depth-Detect
// -----------------------------------------------------------------------------
//  Requirements & Limitations:
//   - ReShade: 5.0 or higher
//   - Anti-Aliasing: Disable MSAA in game settings for depth detection to work.
//   - Generic Depth: Depth Addon must be enabled in ReShade's settings.
//   - Depth Input: The depth input must have the correct polarity
//     (RESHADE_DEPTH_INPUT_IS_REVERSED) to track depth state changes properly.
// -----------------------------------------------------------------------------

#include "ReShade.fxh"

namespace StaticDetect
{

// ------- PREPROCESSOR DEFINITIONS -------

#ifndef RESHADE_DEPTH_INPUT_IS_LOGARITHMIC
    #define RESHADE_DEPTH_INPUT_IS_LOGARITHMIC 0
#endif

#ifndef RESHADE_DEPTH_INPUT_IS_REVERSED
    #define RESHADE_DEPTH_INPUT_IS_REVERSED 0
#endif

#ifndef RESHADE_DEPTH_LINEARIZATION_FAR_PLANE
    #define RESHADE_DEPTH_LINEARIZATION_FAR_PLANE 1000.0
#endif

#ifndef RESHADE_DEPTH_MULTIPLIER
    #define RESHADE_DEPTH_MULTIPLIER 1
#endif

#ifndef NUM_TECH_PAIRS
    #define NUM_TECH_PAIRS 1
#endif

#if (NUM_TECH_PAIRS != 1 && NUM_TECH_PAIRS != 2)
    #error "INVALID CONFIGURATION: [NUM_TECH_PAIRS] must be 1 or 2."
#endif

#ifndef USE_HDR_SUPPORT
    #define USE_HDR_SUPPORT 0
#endif

#if (USE_HDR_SUPPORT != 0 && USE_HDR_SUPPORT != 1)
    #error "INVALID CONFIGURATION: [USE_HDR_SUPPORT] must be 0 or 1."
#endif

#if USE_HDR_SUPPORT
    #define MS_FORMAT RGBA16F
#else
    #define MS_FORMAT RGBA8
#endif

// ------- CONSTANTS & TABLES -------

#define MAX_COLS 60
#define MAX_ROWS 40

static const float MaxScanPoints      = (float)(MAX_COLS * MAX_ROWS);
static const float InvMaxCols         = 1.0f / (float)MAX_COLS;
static const float InvMaxRows         = 1.0f / (float)MAX_ROWS;

static const uint TotalPointsTable[4] = { 24, 96, 384, 2400 };
static const uint GridColsTable[4]    = { 6, 12, 24, 60 };
static const uint GridRowsTable[4]    = { 4, 8, 16, 40 };

static const float GridMargin         = 0.05f;
static const float GridArea           = 0.90f;

static const float BoostTable[5]      = { 1.0f, 10.0f, 100.0f, 1000.0f, 10000.0f };

// ------- UI -------

uniform int Info <
    ui_category = "Info";
    ui_category_closed = true;
    ui_label    = " ";
    ui_type     = "radio";
    ui_text     = "Shader: Static Depth Detect v0.5a\n"
                  "Author: MarineSolder © 2026\n\n"
                  "In many legacy titles, the 3D scene completely freezes during Menu navigation or FMV playback.\n"
                  "This shader tries to detect depth freeze and automatically toggles off/on scene effects (e.g. DOF, AO, RC) to prevent interference with Menu or FMV.\n\n"
                  "USAGE ORDER:\n"
                  "1. StaticDepth_Detect -> Place at the VERY TOP.\n"
                  "2. StaticDepth_Before -> Place BEFORE desired effects.\n"
                  "3. StaticDepth_After  -> Place AFTER desired effects.\n\n"
                  "NUMBER OF TOGGLE PAIRS:\n"
                  "Go to 'Preprocessor definitions' and change NUM_TECH_PAIRS parameter - 1 or 2.\n";
> = 0;

uniform int TogglePairs <
    ui_category = "Configuration";
    ui_label    = "Toggle Pairs";
    ui_type     = "radio";
    ui_text     = 
                  #if NUM_TECH_PAIRS == 2
                    "DUAL PAIR (2x Before/After)"
                  #else
                    "SINGLE PAIR (1x Before/After)"
                  #endif
                  ;
> = 0;

uniform int PassMode <
    ui_category = "Configuration";
    ui_label    = "Passthrough Mode";
    ui_type     = "radio";
    ui_text     = 
                  #if USE_HDR_SUPPORT == 1
                    "HDR 16-bit"
                  #else
                    "SDR 8-bit"
                  #endif
                  ;
> = 0;

uniform int ToggleMode1 <
    ui_category = "Configuration";
    ui_label    = "Pair 1: Trigger Action";
    ui_type     = "combo";
    ui_items    = "Toggles OFF\0Toggles ON\0";
    ui_tooltip  = "Choose Trigger mode for pair group 1.";
> = 0;

#if NUM_TECH_PAIRS > 1
uniform int ToggleMode2 <
    ui_category = "Configuration";
    ui_label    = "Pair 2: Trigger Action";
    ui_type     = "combo";
    ui_items    = "Toggles OFF\0Toggles ON\0";
    ui_tooltip  = "Choose Trigger mode for pair group 2.";
> = 0;
#endif

uniform float FadeSpeed <
    ui_category = "Configuration";
    ui_label    = "Fade Speed";
    ui_type     = "slider";
    ui_min      = 0.1; ui_max = 1.0; ui_step = 0.1;
    ui_tooltip  = "Speed of the fade transition for effects. 0.1 - Smooth fade, 1.0 - Instant (no fade).";
> = 0.9;

uniform int PointsGrid <
    ui_category = "Detection Area"; 
    ui_label    = "Density of Scan Points";
    ui_type     = "combo";
    ui_items    = "Low (6x4)\0Medium (12x8)\0High (24x16)\0Extreme (60x40)\0";
    ui_tooltip  = "Adjusts scan point density to suit different gameplay situations.";
> = 1;

uniform int SensFrames <
    ui_category = "Detection Area"; 
    ui_label    = "Number of Frames";
    ui_type     = "slider";
    ui_min      = 10; ui_max = 300; ui_step = 1;
    ui_tooltip  = "Number of frames the Depth must remain static to activate Trigger.";
> = 30;

uniform int SensLevel <
    ui_category = "Depth Detection"; 
    ui_label    = "Sensitivity Level";
    ui_type     = "slider";
    ui_min      = 1; ui_max = 5;
    ui_tooltip  = "Multiplier for global Depth detection. 1 - Lazy detection, 5 - Aggressive detection.";
> = 4;

uniform int DelayFrames <
    ui_category = "Depth Detection"; 
    ui_label    = "Trigger Buffer (Frames)";
    ui_type     = "slider";
    ui_min      = 0; ui_max = 100; ui_step = 1;
    ui_tooltip  = "Additional idle frames to hold the Trigger active before reset. Use this setting to control rapid toggling (flickering).";
> = 5;

uniform int ReleaseSpeed <
    ui_category = "Depth Detection"; 
    ui_label    = "Trigger Release";
    ui_type     = "slider";
    ui_min      = 1; ui_max = 5; ui_step = 1;
    ui_tooltip  = "Reset speed of the Trigger Buffer. 1 - Slow reset, 5 - Instant reset (1 frame).";
> = 4;

uniform bool ColorValidation <
    ui_category = "Color Detection";
    ui_label    = "Enable Color Monitoring";
    ui_tooltip  = "This may improve detection accuracy in some games, but may cause issues in others.\n"
                  "OFF - Uses Depth detection only, ON - Adds color change monitoring of the scene to protect Trigger stability.";
> = false;

uniform float ColorTolerance <
    ui_category = "Color Detection"; 
    ui_label    = "Tolerance";
    ui_type     = "slider";
    ui_min      = 0.01; ui_max = 0.40; ui_step = 0.01;
    ui_tooltip  = "Minimum color change required for a pixel to be considered in motion.";
> = 0.08;

uniform int RequiredPercent <
    ui_category = "Color Detection"; 
    ui_label    = "Required Motion (%)";
    ui_type     = "slider";
    ui_min      = 1; ui_max = 95; ui_step = 1;
    ui_tooltip  = "Required percentage of moving pixels to confirm the Trigger.";
> = 15;

uniform bool ShowDebugTint < 
    ui_category = "Debug"; 
    ui_label    = "Show Trigger Overlay (Red Tint)"; 
> = true;

uniform bool ShowScanPoints < 
    ui_category = "Debug"; 
    ui_label    = "Show Scan Points (Yellow Dots)"; 
> = true;

// ------- HELPERS -------

float FetchLinearDepth(float2 scanUV)
{
    float depth = tex2Dlod(ReShade::DepthBuffer, float4(scanUV, 0.0f, 0.0f)).r;
    depth *= (float)RESHADE_DEPTH_MULTIPLIER;

    #if RESHADE_DEPTH_INPUT_IS_LOGARITHMIC
        static const float logPrecision = 0.01f;
        depth = (exp(depth * log(logPrecision + 1.0f)) - 1.0f) / logPrecision;
    #endif

    #if RESHADE_DEPTH_INPUT_IS_REVERSED
        depth = 1.0f - depth;
    #endif

    static const float farPlane = (float)RESHADE_DEPTH_LINEARIZATION_FAR_PLANE;
    static const float nearPlane = 1.0f;
    static const float planeRange = farPlane - nearPlane;

    depth /= farPlane - (depth * planeRange);
    return saturate(depth);
}

float2 CalcScanPointUV(const uint col, const uint row, const int mode)
{
    const int gridIndex = clamp(mode, 0, 3);
    const float2 gridIntervals = float2((float)GridColsTable[gridIndex] - 1.0f, (float)GridRowsTable[gridIndex] - 1.0f);

    return float2(GridMargin + ((float)col / gridIntervals.x) * GridArea, 
                  GridMargin + ((float)row / gridIntervals.y) * GridArea);
}

// ------- TEXTURES & SAMPLERS -------

texture MS_TexClean { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = MS_FORMAT; };
sampler MS_SampClean { Texture = MS_TexClean; SRGBTexture = false; };

#if NUM_TECH_PAIRS > 1
texture MS_TexClean2 { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = MS_FORMAT; };
sampler MS_SampClean2 { Texture = MS_TexClean2; SRGBTexture = false; };
#endif

texture MS_TexStateCurr { Width = 1; Height = 1; Format = RGBA32F; };
texture MS_TexStatePrev { Width = 1; Height = 1; Format = RGBA32F; };
sampler MS_SampStateCurr { Texture = MS_TexStateCurr; };
sampler MS_SampStatePrev { Texture = MS_TexStatePrev; };

texture MS_TexPointsCurr { Width = MAX_COLS; Height = MAX_ROWS; Format = R32F; };
texture MS_TexPointsPrev { Width = MAX_COLS; Height = MAX_ROWS; Format = R32F; };
sampler MS_SampPointsCurr { Texture = MS_TexPointsCurr; };
sampler MS_SampPointsPrev { Texture = MS_TexPointsPrev; };

texture MS_TexColorLive { Width = MAX_COLS; Height = MAX_ROWS; Format = RGBA32F; };
texture MS_TexColorCurr { Width = MAX_COLS; Height = MAX_ROWS; Format = RGBA32F; };
texture MS_TexColorPrev { Width = MAX_COLS; Height = MAX_ROWS; Format = RGBA32F; };
sampler MS_SampColorLive { Texture = MS_TexColorLive; };
sampler MS_SampColorCurr { Texture = MS_TexColorCurr; };
sampler MS_SampColorPrev { Texture = MS_TexColorPrev; };

// ------- SHADERS -------

void PS_FetchPoints(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float outDepth : SV_Target)
{
    const uint col = (uint)screenPos.x;
    const uint row = (uint)screenPos.y;
    const int gridIndex = clamp(PointsGrid, 0, 3);

    if (col < GridColsTable[gridIndex] && row < GridRowsTable[gridIndex])
    {
        outDepth = FetchLinearDepth(CalcScanPointUV(col, row, PointsGrid));
    }
    else
    {
        discard;
    }
}

void PS_FetchLiveColor(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    if (!ColorValidation)
    {
        discard;
    }

    const uint col = (uint)screenPos.x;
    const uint row = (uint)screenPos.y;

    if (col < MAX_COLS && row < MAX_ROWS)
    {
        const float2 targetUV = CalcScanPointUV(col, row, 3);
        outColor = float4(tex2Dlod(ReShade::BackBuffer, float4(targetUV, 0.0f, 0.0f)).rgb, 1.0f);
    }
    else
    {
        discard;
    }
}

void PS_AnalyzePoints(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outStateCurr : SV_Target)
{
    float4 prevState = tex2D(MS_SampStatePrev, float2(0.5f, 0.5f));

    if (prevState.a < 0.5f)
    {
        prevState.r = 1.0f; prevState.g = (float)(SensFrames + DelayFrames); prevState.b = 1.0f; prevState.a = 1.0f; 
    }

    const float boostMultiplier = BoostTable[clamp(SensLevel - 1, 0, 4)];

    const int gridIndex = clamp(PointsGrid, 0, 3);
    const uint maxCols = GridColsTable[gridIndex];
    const uint maxRows = GridRowsTable[gridIndex];

    static const float thresholdStatic = 0.0001f;
    static const float thresholdActive = 0.0002f;

    const bool isStatic = (prevState.g > 0.0f);
    const float currentThreshold = isStatic ? thresholdActive : thresholdStatic;

    float maxDepthDelta = 0.0f;
    bool depthBreak = false;

    [loop]
    for (uint y = 0; y < maxRows; y++)
    {
        [loop]
        for (uint x = 0; x < maxCols; x++)
        {
            const float2 fetchUV = float2(((float)x + 0.5f) * InvMaxCols, ((float)y + 0.5f) * InvMaxRows);

            const float depthCurr = tex2Dlod(MS_SampPointsCurr, float4(fetchUV, 0.0f, 0.0f)).r;
            const float depthPrev = tex2Dlod(MS_SampPointsPrev, float4(fetchUV, 0.0f, 0.0f)).r;
            const float depthDiff = abs(depthCurr - depthPrev) * boostMultiplier;

            if (depthDiff > currentThreshold)
            {
                maxDepthDelta = depthDiff;
                depthBreak = true;
                break;
            }
            maxDepthDelta = max(maxDepthDelta, depthDiff);
        }
        if (depthBreak)
        {
            break;
        }
    }

    float frameCount = prevState.g;
    float releaseStep = 0.0f;
    const float requiredFrames = (float)(SensFrames + DelayFrames);

    if (ReleaseSpeed == 5)
    {
        releaseStep = requiredFrames;
    }
    else
    {
        releaseStep = (float)SensFrames * (0.05f * exp2((float)ReleaseSpeed - 1.0f));
    }
    if (maxDepthDelta < currentThreshold)
    {
        frameCount = min(frameCount + 1.0f, requiredFrames);
    }
    else
    {
        frameCount = max(frameCount - releaseStep, 0.0f);
    }

    float globalLatch = prevState.b;

    if (frameCount >= (float)SensFrames)
    {
        if (!ColorValidation)
        {
            globalLatch = 1.0f;
        }
        else if (globalLatch == 0.0f)
        {
            float changedPixels = 0.0f;
            const float sqColorTolerance = ColorTolerance * ColorTolerance;

            [loop]
            for (uint cy = 0; cy < MAX_ROWS; cy++)
            {
                [loop]
                for (uint cx = 0; cx < MAX_COLS; cx++)
                {
                    const float2 fetchUV = float2(((float)cx + 0.5f) * InvMaxCols, ((float)cy + 0.5f) * InvMaxRows);

                    const float3 baseColor = tex2Dlod(MS_SampColorPrev, float4(fetchUV, 0.0f, 0.0f)).rgb;
                    const float3 currColor = tex2Dlod(MS_SampColorLive, float4(fetchUV, 0.0f, 0.0f)).rgb;
                    const float3 diffColor = currColor - baseColor;

                    if (dot(diffColor, diffColor) > sqColorTolerance)
                    {
                        changedPixels += 1.0f;
                    }
                }
            }

            const float changedPercent = (changedPixels / MaxScanPoints) * 100.0f;

            if (changedPercent >= (float)RequiredPercent)
            {
                globalLatch = 1.0f;
            }
        }
    }
    else if (frameCount <= 0.0f)
    {
        globalLatch = 0.0f;
    }

    const float fadeFactor = FadeSpeed * FadeSpeed;
    const float currentFade = lerp(prevState.r, globalLatch, fadeFactor);

    outStateCurr = float4(currentFade, frameCount, globalLatch, prevState.a);
}

void PS_UpdateState(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outStatePrev : SV_Target)
{
    outStatePrev = tex2D(MS_SampStateCurr, float2(0.5f, 0.5f));
}

void PS_UpdatePoints(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float outDepth : SV_Target)
{
    const uint col = (uint)screenPos.x;
    const uint row = (uint)screenPos.y;
    const int gridIndex = clamp(PointsGrid, 0, 3);

    if (col < GridColsTable[gridIndex] && row < GridRowsTable[gridIndex])
    {
        outDepth = tex2Dlod(MS_SampPointsCurr, float4(scanUV, 0.0f, 0.0f)).r;
    }
    else
    {
        discard;
    }
}

void PS_UpdateColorCurr(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outLiveColor : SV_Target)
{
    if (!ColorValidation) discard;

    const uint col = (uint)screenPos.x;
    const uint row = (uint)screenPos.y;

    if (col < MAX_COLS && row < MAX_ROWS)
    {
        const float4 currState = tex2Dlod(MS_SampStateCurr, float4(0.5f, 0.5f, 0.0f, 0.0f));

        if (currState.g == 0.0f)
        {
            outLiveColor = tex2Dlod(MS_SampColorLive, float4(scanUV, 0.0f, 0.0f));
        }
        else
        {
            outLiveColor = tex2Dlod(MS_SampColorPrev, float4(scanUV, 0.0f, 0.0f));
        }
    }
    else
    {
        discard;
    }
}

void PS_UpdateColorPrev(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColorPrev : SV_Target)
{
    if (!ColorValidation)
    {
        discard;
    }
    outColorPrev = tex2Dlod(MS_SampColorCurr, float4(scanUV, 0.0f, 0.0f));
}

void PS_SaveBackBuffer(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    outColor = tex2D(ReShade::BackBuffer, scanUV);
}

#if NUM_TECH_PAIRS > 1
void PS_SaveBackBuffer2(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    outColor = tex2D(ReShade::BackBuffer, scanUV);
}
#endif

void PS_ApplyToggle(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    const float4 currState = tex2D(MS_SampStateCurr, float2(0.5f, 0.5f));
    const float currentFade = currState.r;

    const float4 cleanFrame = tex2D(MS_SampClean, scanUV);
    const float4 processFrame = tex2D(ReShade::BackBuffer, scanUV);

    if (ToggleMode1 == 0)
    {
        outColor = lerp(processFrame, cleanFrame, currentFade);
    }
    else
    {
        outColor = lerp(cleanFrame, processFrame, currentFade);
    }

    if (ShowDebugTint && currentFade > 0.001f)
    {
        outColor.rgb = lerp(outColor.rgb, float3(1.0f, 0.0f, 0.0f), 0.3f * currentFade);
    }

    if (ShowScanPoints)
    {
        const int gridIndex = clamp(PointsGrid, 0, 3);
        const float2 gridGaps = float2((float)GridColsTable[gridIndex] - 1.0f, (float)GridRowsTable[gridIndex] - 1.0f);
        const float2 screenRes = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
        const float dotSize = max(1.0f, round((float)BUFFER_HEIGHT / 720.0f));

        float2 nearestIndex = round(((scanUV - GridMargin) / GridArea) * gridGaps);
        nearestIndex = clamp(nearestIndex, 0.0f, gridGaps);

        const float2 targetUV = GridMargin + (nearestIndex / gridGaps) * GridArea;
        const float2 distPixels = abs(scanUV - targetUV) * screenRes;

        if (distPixels.x < dotSize && distPixels.y < dotSize) 
        {
            float3 dotColor = float3(1.0f, 1.0f, 0.0f);

            if (ColorValidation && currState.g >= (float)SensFrames && currState.b == 0.0f)
            {
                dotColor = float3(0.0f, 0.5f, 1.0f);
            }
            outColor.rgb = dotColor;
        }
    }
}

#if NUM_TECH_PAIRS > 1
void PS_ApplyToggle2(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    const float4 currState = tex2D(MS_SampStateCurr, float2(0.5f, 0.5f));
    const float currentFade = currState.r;

    const float4 cleanFrame = tex2D(MS_SampClean2, scanUV);
    const float4 processFrame = tex2D(ReShade::BackBuffer, scanUV);

    if (ToggleMode2 == 0)
    {
        outColor = lerp(processFrame, cleanFrame, currentFade);
    }
    else
    {
        outColor = lerp(cleanFrame, processFrame, currentFade);
    }
}
#endif

}

// ------- TECHNIQUES -------

technique StaticDepth_Detect
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_FetchPoints;     RenderTarget = StaticDetect::MS_TexPointsCurr; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_FetchLiveColor;  RenderTarget = StaticDetect::MS_TexColorLive; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_AnalyzePoints;   RenderTarget = StaticDetect::MS_TexStateCurr; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_UpdateState;     RenderTarget = StaticDetect::MS_TexStatePrev; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_UpdatePoints;    RenderTarget = StaticDetect::MS_TexPointsPrev; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_UpdateColorCurr; RenderTarget = StaticDetect::MS_TexColorCurr; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_UpdateColorPrev; RenderTarget = StaticDetect::MS_TexColorPrev; }
}

technique StaticDepth_Before
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_SaveBackBuffer; RenderTarget = StaticDetect::MS_TexClean; }
}

technique StaticDepth_After
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_ApplyToggle; }
}

#if NUM_TECH_PAIRS > 1
technique StaticDepth_Before_2
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_SaveBackBuffer2; RenderTarget = StaticDetect::MS_TexClean2; }
}

technique StaticDepth_After_2
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_ApplyToggle2; }
}
#endif
