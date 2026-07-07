// ----------------------------------------------------------------------------------------------
//  Shader Name:  Static Depth Detect
// ----------------------------------------------------------------------------------------------
//  Version:  0.8a
//  Author:   MarineSolder © 2026
//  License:  Custom Non-Commercial License
//  Source:   https://github.com/MarineSolder/Static-Depth-Detect
// ----------------------------------------------------------------------------------------------
//  Requirements & Limitations:
//    - ReShade:        6.0 or higher.
//    - Graphics API:   DirectX 9.0c, 10, 11 - full support.
//                      DirectX 12, OpenGL 4.x, Vulkan - depends on game's depth buffer support.
//    - Anti-Aliasing:  Disable MSAA in game settings for depth detection to work.
//    - Generic Depth:  Depth Addon must be enabled in ReShade's settings.
//    - Depth Input:    The depth input must have the correct polarity
//                      (RESHADE_DEPTH_INPUT_IS_REVERSED) to track depth state changes properly.
// ----------------------------------------------------------------------------------------------
//  Known Issues:
//    - Unprocessed frames can leak for tens (hundreds) of milliseconds during rapid
//      'Menu -> Game' transitions due to Trigger decision latency. Set 'Trigger Buffer' and
//      'Delay Buffer' to min, and 'Release Speed' to max to test the behavior.
// ----------------------------------------------------------------------------------------------

#include "ReShade.fxh"

#if DEVELOPER_MODE == 1
    #include "DrawText.fxh"
#endif

namespace StaticDetect
{

// ================================== PREPROCESSOR DEFINITIONS ==================================

#if !defined(ADDON_GENERIC_DEPTH)
    #error "Generic Depth Addon must be enabled [Add-ons -> Generic Depth]"
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

#if USE_HDR_SUPPORT == 1
    #define PASS_FORMAT RGBA16F
#else
    #define PASS_FORMAT RGBA8
#endif

// ================================ CONSTANTS, TABLES & SOURCES =================================

#if (BUFFER_WIDTH * 1 > BUFFER_HEIGHT * 2)
    #define MAX_COLS 80
    #define MAX_ROWS 40
    #define SECTOR_COLS 8
    #define SECTOR_ROWS 4
    #define SECTOR_REQUIRED 16

    static const uint GridColsTable[4] = { 8, 16, 32, 80 };
    static const uint GridRowsTable[4] = { 4,  8, 16, 40 };
#else
    #define MAX_COLS 60
    #define MAX_ROWS 40
    #define SECTOR_COLS 6
    #define SECTOR_ROWS 4
    #define SECTOR_REQUIRED 12

    static const uint GridColsTable[4] = { 6, 12, 24, 60 };
    static const uint GridRowsTable[4] = { 4,  8, 16, 40 };
#endif

static const int StartupFrames       = 5;

static const float InvMaxCols        = 1.0 / MAX_COLS;
static const float InvMaxRows        = 1.0 / MAX_ROWS;

static const float GridMargin        = 0.05;
static const float GridArea          = 0.90;

static const float SensBoostTable[5] = { 1.0, 10.0, 100.0, 1000.0, 10000.0 };
static const float LowerThreshold    = 0.0005;
static const float UpperThreshold    = 0.5;

uniform float FrameTime < source = "frametime"; >;
uniform int FrameCount  < source = "framecount"; >;

#if DEVELOPER_MODE == 1
uniform bool DepthBufferReady < source = "bufready_depth"; >;
#endif

// ======================================= UI (UNIFORMS) ========================================

uniform int Info <
    ui_category = "Info";
    ui_category_closed = true;
    ui_label    = " ";
    ui_type     = "radio";
    ui_text     = "Shader: Static Depth Detect v0.8a\n"
                  "Author: MarineSolder © 2026\n\n"
                  "In many legacy titles, the 3D scene completely freezes during Menu navigation or FMV playback.\n"
                  "This shader detects depth freeze and automatically toggles desired effects off/on to prevent interference with Menu or FMV.\n\n"
                  "USAGE ORDER:\n"
                  "1. StaticDepth_Detect -> Place at the VERY TOP.\n"
                  "2. StaticDepth_Before -> Place BEFORE desired effects.\n"
                  "3. StaticDepth_After  -> Place AFTER desired effects.\n\n"
                  "NUMBER OF TOGGLE PAIRS:\n"
                  "Go to 'Preprocessor definitions' and change NUM_TECH_PAIRS parameter - 1 or 2.\n\n"
                  "HDR SUPPORT:\n"
                  "Go to 'Preprocessor definitions' and change USE_HDR_SUPPORT parameter - 0 or 1.\n";
> = 0;

uniform int TogglePairs <
    ui_category = "Configuration";
    ui_label    = "Toggle Pairs";
    ui_type     = "radio";
    ui_text     = 
                  #if NUM_TECH_PAIRS == 2
                    "DUAL PAIR (2x Before/After)";
                  #else
                    "SINGLE PAIR (1x Before/After)";
                  #endif
> = 0;

uniform int PassMode <
    ui_category = "Configuration";
    ui_label    = "Passthrough Mode";
    ui_type     = "radio";
    ui_text     = 
                  #if USE_HDR_SUPPORT == 1
                    "HDR 16-bit";
                  #else
                    "SDR 8-bit";
                  #endif
> = 0;

uniform int ToggleMode1 <
    ui_category = "Configuration";
    ui_label    = "Pair 1: Trigger Action";
    ui_type     = "combo";
    ui_items    = "Toggles OFF\0Toggles ON\0";
    ui_tooltip  = "Choose Trigger mode for pair group 1.";
> = 0;

#if NUM_TECH_PAIRS == 2
uniform int ToggleMode2 <
    ui_category = "Configuration";
    ui_label    = "Pair 2: Trigger Action";
    ui_type     = "combo";
    ui_items    = "Toggles OFF\0Toggles ON\0";
    ui_tooltip  = "Choose Trigger mode for pair group 2.";
> = 0;
#endif

uniform bool UseFadeTransition <
    ui_category = "Configuration";
    ui_label    = "Add Fade Transition";
    ui_tooltip  = "Adds a smooth fade transition to the screen when the Trigger toggles.\n"
                  "OFF - Instant discrete toggle (no fade).\n"
                  "ON  - Use fade between processed and clean frame.";
> = true;

uniform int FadeStyle <
    ui_category = "Configuration";
    ui_label    = "Fade Style";
    ui_type     = "combo";
    ui_items    = "Crossfade\0Saturation Pulse\0Warp Streak\0Rack Focus\0Zoom Blur\0"
                  "Chroma Split\0Digital Glitch\0Block Dissolve\0Mosaic Shatter\0"
                  "Film Burn\0Vertical Wipe\0Circle Wipe\0";
> = 0;

uniform int FadeSpeed <
    ui_category = "Configuration";
    ui_label    = "Fade Speed";
    ui_type     = "slider";
    ui_min      = 1; ui_max = 10; ui_step = 1;
    ui_tooltip  = "Speed of the fade transition. 1 - Smooth fade, 10 - Fast fade.";
> = 9;

uniform int PointsGrid <
    ui_category = "Depth Detection";
    ui_label    = "Density of Scan Points";
    ui_type     = "combo";
    ui_items    = 
                  #if (BUFFER_WIDTH * 1 > BUFFER_HEIGHT * 2)
                    "Low (8x4)\0Medium (16x8)\0High (32x16)\0Extreme (80x40)\0";
                  #else
                    "Low (6x4)\0Medium (12x8)\0High (24x16)\0Extreme (60x40)\0";
                  #endif
    ui_tooltip  = "Scan Points act as Depth sensors distributed across the screen.\n"
                  "Extreme - recommended only for games with a small amount of 3D objects on screen.";
> = 1;

uniform int SensLevel <
    ui_category = "Depth Detection";
    ui_label    = "Sensitivity Level";
    ui_type     = "slider";
    ui_min      = 1; ui_max = 5; ui_step = 1;
    ui_tooltip  = "Multiplier for Depth sensitivity. 1 - Lazy detection, 5 - Aggressive detection.";
> = 4;

uniform int TriggerBuffer <
    ui_category = "Depth Detection";
    ui_label    = "Trigger Buffer (ms)";
    ui_type     = "slider";
    ui_min      = 20; ui_max = 2000; ui_step = 50;
    ui_tooltip  = "How long the Depth must remain static to activate Trigger.\n"
                  "This is the main timing parameter of the Trigger.";
> = 250;

uniform int DelayBuffer <
    ui_category = "Depth Detection";
    ui_label    = "Delay Buffer (ms)";
    ui_type     = "slider";
    ui_min      = 0; ui_max = 500; ui_step = 50;
    ui_tooltip  = "How long to hold the Trigger active before reset.\n"
                  "Use it to add delay to Trigger decision if Depth freeze is unstable.";
> = 100;

uniform int ReleaseSpeed <
    ui_category = "Depth Detection";
    ui_label    = "Trigger Release";
    ui_type     = "slider";
    ui_min      = 1; ui_max = 10; ui_step = 1;
    ui_tooltip  = "Reset speed of the Trigger Buffer. 1 - Slow reset, 10 - Instant reset.\n"
                  "Use this setting to control rapid toggling (flickering).";
> = 9;

uniform bool UseColorDetection <
    ui_category = "Color Detection";
    ui_label    = "Enable Color-Jump Detection";
    ui_tooltip  = "This may improve or break global detection accuracy, depending on the game.\n"
                  "OFF - Uses Depth detection only.\n"
                  "ON  - Adds color change monitoring of the scene to help Trigger with decision.";
> = false;

uniform int ColorTolerance <
    ui_category = "Color Detection";
    ui_label    = "Tolerance (%)";
    ui_type     = "slider";
    ui_min      = 1; ui_max = 40; ui_step = 1;
    ui_tooltip  = "Minimum color difference required for a pixel to be considered as \"changed\".";
> = 10;

uniform int RequiredPercent <
    ui_category = "Color Detection";
    ui_label    = "Required Change (%)";
    ui_type     = "slider";
    ui_min      = 1; ui_max = 90; ui_step = 1;
    ui_tooltip  = "Required percentage of changed pixels to confirm the \"color-jump\".";
> = 15;

uniform float DepthSmoothAlpha <
    ui_category = "Advanced Tuning";
    ui_type     = "slider";
    ui_min      = 0.1; ui_max = 1.0; ui_step = 0.1;
    ui_tooltip  = "EMA smoothing factor for depth-delta.\n"
                  "Lower - smoother reaction to depth changes, higher - faster reaction.\n"
                  "0.3 - 8 frames, 0.4 - 6 frames, 0.5 - 4 frames, 0.7 - 3 frames.";
#if DEVELOPER_MODE != 1
    hidden      = true;
#endif
> = 0.6;

uniform float ColorSmoothAlpha <
    ui_category = "Advanced Tuning";
    ui_type     = "slider";
    ui_min      = 0.1; ui_max = 1.0; ui_step = 0.1;
    ui_tooltip  = "EMA smoothing factor for color change percentage.\n"
                  "Lower - smoother reaction to color changes, higher - faster reaction.\n"
                  "0.3 - 8 frames, 0.4 - 6 frames, 0.5 - 4 frames, 0.7 - 3 frames.";
#if DEVELOPER_MODE != 1
    hidden      = true;
#endif
> = 0.4;

uniform float ColorWakeupOffsetMs <
    ui_category = "Advanced Tuning";
    ui_type     = "slider";
    ui_min      = 0.0; ui_max = 500.0; ui_step = 50.0;
    ui_tooltip  = "How many ms before the Depth Trigger fires to start color sampling.\n"
                  "Gives color EMA time to accumulate before the trigger decision.";
#if DEVELOPER_MODE != 1
    hidden      = true;
#endif
> = 150.0;

uniform float SnapshotCooldownMs <
    ui_category = "Advanced Tuning";
    ui_type     = "slider";
    ui_min      = 0.0; ui_max = 500.0; ui_step = 50.0;
    ui_tooltip  = "How long the scene must stay in motion before the color baseline is refreshed.\n"
                  "Prevents rapid menu spam from overwriting the last valid gameplay anchor.";
#if DEVELOPER_MODE != 1
    hidden      = true;
#endif
> = 150.0;

uniform float LocalSectorThreshold <
    ui_category = "Advanced Tuning";
    ui_type     = "slider";
    ui_min      = 10.0; ui_max = 90.0; ui_step = 5.0;
    ui_tooltip  = "Percent of \"changed\" pixels within sector must reach this to count as \"detected\" sector.\n"
                  "Lower - sectors trigger more easily (sensitive), higher - stricter per-sector gate.";
#if DEVELOPER_MODE != 1
    hidden      = true;
#endif
> = 40.0;

uniform bool ShowDebugTint <
    ui_category = "Debug";
    ui_label    = "Show Trigger Signal (Red Overlay)";
> = true;

uniform bool ShowScanPoints <
    ui_category = "Debug";
    ui_label    = "Show Scan Points (Yellow Dots)";
> = true;

#if DEVELOPER_MODE == 1
uniform bool ShowDiagnostics <
    ui_category = "Debug";
    ui_label    = "Show Advanced Diagnostics";
> = false;
#endif

// ==================================== TEXTURES & SAMPLERS =====================================

texture2D Tex_Clean { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = PASS_FORMAT; };
sampler2D Samp_Clean { Texture = Tex_Clean; SRGBTexture = false; };

#if NUM_TECH_PAIRS == 2
texture2D Tex_Clean2 { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = PASS_FORMAT; };
sampler2D Samp_Clean2 { Texture = Tex_Clean2; SRGBTexture = false; };
#endif

texture2D Tex_StateCurr1 { Width = 1; Height = 1; Format = RGBA32F; };
texture2D Tex_StatePrev1 { Width = 1; Height = 1; Format = RGBA32F; };
sampler2D Samp_StateCurr1 { Texture = Tex_StateCurr1; };
sampler2D Samp_StatePrev1 { Texture = Tex_StatePrev1; };
texture2D Tex_StateCurr2 { Width = 1; Height = 1; Format = RGBA32F; };
texture2D Tex_StatePrev2 { Width = 1; Height = 1; Format = RGBA32F; };
sampler2D Samp_StateCurr2 { Texture = Tex_StateCurr2; };
sampler2D Samp_StatePrev2 { Texture = Tex_StatePrev2; };

#if DEVELOPER_MODE == 1
texture2D Tex_StateCurr3 { Width = 1; Height = 1; Format = RGBA16F; };
sampler2D Samp_StateCurr3 { Texture = Tex_StateCurr3; };
#endif

texture2D Tex_DepthCurr { Width = MAX_COLS; Height = MAX_ROWS; Format = R32F; };
texture2D Tex_DepthPrev { Width = MAX_COLS; Height = MAX_ROWS; Format = R32F; };
sampler2D Samp_DepthCurr { Texture = Tex_DepthCurr; MinFilter = POINT; MagFilter = POINT; };
sampler2D Samp_DepthPrev { Texture = Tex_DepthPrev; MinFilter = POINT; MagFilter = POINT; };

texture2D Tex_ColorLive { Width = MAX_COLS; Height = MAX_ROWS; Format = RGBA8; };
texture2D Tex_ColorCurr { Width = MAX_COLS; Height = MAX_ROWS; Format = RGBA8; };
texture2D Tex_ColorSnap { Width = MAX_COLS; Height = MAX_ROWS; Format = RGBA8; };
sampler2D Samp_ColorLive { Texture = Tex_ColorLive; MinFilter = POINT; MagFilter = POINT; SRGBTexture = false; };
sampler2D Samp_ColorCurr { Texture = Tex_ColorCurr; MinFilter = POINT; MagFilter = POINT; SRGBTexture = false; };
sampler2D Samp_ColorSnap { Texture = Tex_ColorSnap; MinFilter = POINT; MagFilter = POINT; SRGBTexture = false; };

// ========================================== HELPERS ===========================================

float GetStableDepth(float2 scanUV)
{
    return saturate(ReShade::GetLinearizedDepth(scanUV));
}

float2 CalcScanPointUV(uint col, uint row, int mode)
{
    int gridIndex   = clamp(mode, 0, 3);
    float2 gridGaps = float2(GridColsTable[gridIndex] - 1.0, GridRowsTable[gridIndex] - 1.0);

    return GridMargin + (float2(col, row) / gridGaps) * GridArea;
}

float2 GetColorJumpPercent()
{
    const uint rowsPerSector = MAX_ROWS / SECTOR_ROWS;
    const uint colsPerSector = MAX_COLS / SECTOR_COLS;
    const float sectorPixels = rowsPerSector * colsPerSector;

    float sqColorTolerance = (ColorTolerance / 100.0) * (ColorTolerance / 100.0);
    float reqSectorPixels = sectorPixels * (LocalSectorThreshold / 100.0);

    float changedPixels   = 0.0;
    float detectedSectors = 0.0;

    [loop]
    for (uint sy = 0; sy < SECTOR_ROWS; sy++)
    {
        [loop]
        for (uint sx = 0; sx < SECTOR_COLS; sx++)
        {
            float currSectorCount = 0.0;

            [loop]
            for (uint py = 0; py < rowsPerSector; py++)
            {
                uint cy = (sy * rowsPerSector) + py;

                [loop]
                for (uint px = 0; px < colsPerSector; px++)
                {
                    uint cx = (sx * colsPerSector) + px;
                    float2 pointUV   = float2((cx + 0.5) * InvMaxCols, (cy + 0.5) * InvMaxRows);

                    float3 baseColor = tex2Dlod(Samp_ColorSnap, float4(pointUV, 0.0, 0.0)).rgb;
                    float3 currColor = tex2Dlod(Samp_ColorLive, float4(pointUV, 0.0, 0.0)).rgb;
                    float3 colorDiff = currColor - baseColor;

                    if (dot(colorDiff, colorDiff) > sqColorTolerance)
                    {
                        changedPixels   += 1.0;
                        currSectorCount += 1.0;
                    }
                }
            }

            detectedSectors += (currSectorCount >= reqSectorPixels) ? 1.0 : 0.0;
        }
    }

    return float2((changedPixels / (MAX_COLS * MAX_ROWS)) * 100.0, detectedSectors);
}

#if DEVELOPER_MODE == 1
bool GetThumbUV(float2 screenPos, float2 thumbPos, float2 thumbDim, float borderSize, out float2 uv,
                                                                                       inout float3 color)
{
    uv = 0.0;
    float2 local = screenPos - thumbPos;

    if (any(local < -borderSize) || any(local >= thumbDim + borderSize))
    {
        return false;
    }

    if (any(local < 0.0) || any(local >= thumbDim))
    {
        color = 1.0;
        return false;
    }

    uv = local / thumbDim;
    return true;
}
#endif

float4 ProcessVertexKill(uint id, int toggleMode, out float2 texcoord)
{
    texcoord.x = (id == 2) ? 2.0 : 0.0;
    texcoord.y = (id == 1) ? 2.0 : 0.0;
    float4 position = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);

    bool debugActive = ShowDebugTint || ShowScanPoints
#if DEVELOPER_MODE == 1
                                     || ShowDiagnostics
#endif
        ;

    [branch]
    if (!debugActive)
    {
        float currFade = tex2Dlod(Samp_StateCurr1, float4(0.5, 0.5, 0.0, 0.0)).r;
        float prevFade = tex2Dlod(Samp_StatePrev1, float4(0.5, 0.5, 0.0, 0.0)).r;

        bool idleOff = (toggleMode == 0) && (currFade < 0.0001) && (prevFade < 0.0001);
        bool idleOn  = (toggleMode == 1) && (currFade > 1.0 - 0.0001) && (prevFade > 1.0 - 0.0001);

        if (idleOff || idleOn)
        {
            return float4(-100000.0, -100000.0, 0.0, 1.0);
        }
    }

    return position;
}

// ====================================== FADE TRANSITIONS ======================================

float TransitionPulse(float currFade)
{
    return 4.0 * currFade * (1.0 - currFade);
}

float FadeHash(float2 p)
{
    float3 p3 = frac(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);

    return frac((p3.x + p3.y) * p3.z);
}

float FadeNoise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);

    float a  = FadeHash(i);
    float b  = FadeHash(i + float2(1.0, 0.0));
    float c  = FadeHash(i + float2(0.0, 1.0));
    float d  = FadeHash(i + float2(1.0, 1.0));

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

void GetVoronoiCell(float2 p, out float2 cellId, out float minDist, out float edgeDist)
{
    minDist  = 8.0;
    edgeDist = 8.0;

    float2 baseCell  = floor(p);
    float2 nearestId = baseCell;

    [unroll]
    for (int y = -1; y <= 1; y++)
    {
        [unroll]
        for (int x = -1; x <= 1; x++)
        {
            float2 neighborId   = baseCell + float2(x, y);
            float2 featurePoint = neighborId + float2(FadeHash(neighborId), FadeHash(neighborId + 17.13)) * 0.7 + 0.15;
            float dist          = length(featurePoint - p);

            if (dist < minDist)
            {
                edgeDist  = minDist;
                minDist   = dist;
                nearestId = neighborId;
            }
            else if (dist < edgeDist)
            {
                edgeDist = dist;
            }
        }
    }

    cellId = nearestId;
}

float4 BlendToggle(sampler2D cleanSampler, float2 scanUV, float currFade, int toggleMode, bool globalTrigger)
{
    const float3 rec709Luma          = float3(0.2126, 0.7152, 0.0722);
    const float goldenRatioConjugate = 0.6180340;
    const float seedScale            = 101.0;

    float windowFrames    = lerp(620.0, 80.0, saturate((FadeSpeed - 1.0) / 9.0));
    float transitionSeed  = frac(floor((float)FrameCount / windowFrames) * goldenRatioConjugate);

    float4 cleanFrame     = tex2Dlod(cleanSampler, float4(scanUV, 0.0, 0.0));
    float4 processedFrame = tex2Dlod(ReShade::BackBuffer, float4(scanUV, 0.0, 0.0));

    float4 baseBlend;

    if (toggleMode == 0)
    {
        baseBlend = lerp(processedFrame, cleanFrame, currFade);
    }
    else
    {
        baseBlend = lerp(cleanFrame, processedFrame, currFade);
    }

    [branch]
    if (FadeStyle == 0)
    {
        return baseBlend;
    }
    else if (FadeStyle == 1)
    {
        const float extraSaturation = 1.0;
        const float redShift        = -0.04;
        const float blueShift       = 0.02;

        float pulseCurve = TransitionPulse(currFade);
        float luma       = dot(baseBlend.rgb, rec709Luma);
        float3 saturated = lerp(luma, baseBlend.rgb, 1.0 + pulseCurve * extraSaturation);
        float3 warmed    = saturated + float3(pulseCurve * redShift, 0.0, pulseCurve * blueShift);

        return float4(saturate(warmed), baseBlend.a);
    }
    else if (FadeStyle == 2)
    {
        const int streakTaps        = 8;
        const float streakThreshold = 0.35;
        const float streakLength    = 0.14;
        const float streakIntensity = 2.5;

        float streakCurve  = TransitionPulse(currFade);
        float2 dir         = scanUV - 0.5;
        float3 streakAccum = 0.0;

        [unroll]
        for (int i = 1; i <= streakTaps; i++)
        {
            float t            = (float)i / (float)streakTaps;
            float2 sampleUV    = scanUV + dir * t * streakCurve * streakLength;
            float3 sampleColor = tex2Dlod(ReShade::BackBuffer, float4(sampleUV, 0.0, 0.0)).rgb;
            float luma         = dot(sampleColor, rec709Luma);
            streakAccum       += sampleColor * saturate(luma - streakThreshold) * (1.0 - t);
        }

        streakAccum *= streakCurve / streakTaps;

        return float4(saturate(baseBlend.rgb + streakAccum * streakIntensity), baseBlend.a);
    }
    else if (FadeStyle == 3)
    {
        const float tau                = 6.2831853;
        const float goldenAngle        = 2.3999632;
        const int diskTaps             = 16;
        const float maxBlurRadius      = 0.006;
        const float blurCurveSteepness = 1.7;

        float blurCurve = TransitionPulse(currFade);
        float maxRadius = blurCurve * maxBlurRadius;

        float ang = FadeHash(scanUV + transitionSeed) * tau;
        float sin, cos;
        sincos(ang, sin, cos);
        float2 dir = float2(cos, sin);
        float gaSin, gaCos;
        sincos(goldenAngle, gaSin, gaCos);

        float4 blurredClean     = 0.0;
        float4 blurredProcessed = 0.0;

        [unroll]
        for (int i = 0; i < diskTaps; i++)
        {
            float radius      = sqrt(((float)i + 0.5) / (float)diskTaps) * maxRadius;
            float2 offsetUV   = scanUV + dir * radius * float2(1.0 / ReShade::AspectRatio, 1.0);
            blurredClean     += tex2Dlod(cleanSampler, float4(offsetUV, 0.0, 0.0));
            blurredProcessed += tex2Dlod(ReShade::BackBuffer, float4(offsetUV, 0.0, 0.0));

            dir = float2(dir.x * gaCos - dir.y * gaSin, dir.x * gaSin + dir.y * gaCos);
        }

        float blurAmount = saturate(blurCurve * blurCurveSteepness);
        blurredClean     = lerp(cleanFrame, blurredClean / diskTaps, blurAmount);
        blurredProcessed = lerp(processedFrame, blurredProcessed / diskTaps, blurAmount);

        if (toggleMode == 0)
        {
            return lerp(blurredProcessed, blurredClean, currFade);
        }
        else
        {
            return lerp(blurredClean, blurredProcessed, currFade);
        }
    }
    else if (FadeStyle == 4)
    {
        const int sampleCount    = 10;
        const float zoomStrength = 0.07;

        float zoomCurve = TransitionPulse(currFade);
        float2 dir      = scanUV - 0.5;
        float jitter    = FadeHash(scanUV + transitionSeed) - 0.5;

        float4 blurredClean     = 0.0;
        float4 blurredProcessed = 0.0;

        [unroll]
        for (int i = 0; i < sampleCount; i++)
        {
            float t = ((float)i + jitter) / (float)(sampleCount - 1) - 0.5;
            float2 offsetUV   = scanUV - dir * t * zoomCurve * zoomStrength;
            blurredClean     += tex2Dlod(cleanSampler, float4(offsetUV, 0.0, 0.0));
            blurredProcessed += tex2Dlod(ReShade::BackBuffer, float4(offsetUV, 0.0, 0.0));
        }

        blurredClean     /= sampleCount;
        blurredProcessed /= sampleCount;

        if (toggleMode == 0)
        {
            return lerp(blurredProcessed, blurredClean, currFade);
        }
        else
        {
            return lerp(blurredClean, blurredProcessed, currFade);
        }
    }
    else if (FadeStyle == 5)
    {
        const float chromaShift = 0.006;

        float chromaCurve = TransitionPulse(currFade);
        float shift       = chromaCurve * chromaShift;

        float rProcessed = tex2Dlod(ReShade::BackBuffer, float4(scanUV - float2(shift, 0.0), 0.0, 0.0)).r;
        float rClean     = tex2Dlod(cleanSampler, float4(scanUV - float2(shift, 0.0), 0.0, 0.0)).r;
        float bProcessed = tex2Dlod(ReShade::BackBuffer, float4(scanUV + float2(shift, 0.0), 0.0, 0.0)).b;
        float bClean     = tex2Dlod(cleanSampler, float4(scanUV + float2(shift, 0.0), 0.0, 0.0)).b;

        float r, b;

        if (toggleMode == 0)
        {
            r = lerp(rProcessed, rClean, currFade);
            b = lerp(bProcessed, bClean, currFade);
        }
        else
        {
            r = lerp(rClean, rProcessed, currFade);
            b = lerp(bClean, bProcessed, currFade);
        }

        return float4(r, baseBlend.g, b, baseBlend.a);
    }
    else if (FadeStyle == 6)
    {
        const float rows             = 120.0;
        const float cols             = 24.0;
        const float glitchDensity    = 0.14;
        const float flickerSpeed     = 50.0;
        const float maxDisplaceX     = 0.020;
        const float maxRowsDisplaceY = 3.0;
        const float rgbShift         = 0.004;

        float glitchCurve = TransitionPulse(currFade);
        float shift       = glitchCurve * rgbShift;

        float lineSeed = floor(scanUV.y * rows);
        float colSeed  = floor(scanUV.x * cols);
        float timeSeed = floor(currFade * flickerSpeed) + transitionSeed * seedScale;

        float blockNoise    = FadeHash(float2(colSeed, lineSeed) + timeSeed);
        float isGlitchBlock = step(1 - glitchDensity, blockNoise);

        float dirNoiseX = FadeHash(float2(colSeed + 11.1, lineSeed) + timeSeed);
        float dirNoiseY = FadeHash(float2(colSeed, lineSeed + 22.2) + timeSeed);
        float displaceX = (dirNoiseX - 0.5) * (2.0 * maxDisplaceX) * glitchCurve;
        float displaceY = (dirNoiseY - 0.5) * 2.0 * (maxRowsDisplaceY / rows) * glitchCurve;

        float2 glitchUV = scanUV + float2(displaceX, displaceY) * isGlitchBlock;

        float r = lerp(tex2Dlod(ReShade::BackBuffer, float4(glitchUV - float2(shift, 0.0), 0.0, 0.0)).r,
                       tex2Dlod(cleanSampler, float4(glitchUV - float2(shift, 0.0), 0.0, 0.0)).r, currFade);
        float g = lerp(tex2Dlod(ReShade::BackBuffer, float4(glitchUV, 0.0, 0.0)).g,
                       tex2Dlod(cleanSampler, float4(glitchUV, 0.0, 0.0)).g, currFade);
        float b = lerp(tex2Dlod(ReShade::BackBuffer, float4(glitchUV + float2(shift, 0.0), 0.0, 0.0)).b,
                       tex2Dlod(cleanSampler, float4(glitchUV + float2(shift, 0.0), 0.0, 0.0)).b, currFade);

        return float4(r, g, b, baseBlend.a);
    }
    else if (FadeStyle == 7)
    {
        const float blockDensity = 12.0;
        const float fadeDuration = 0.1;

        const float2 blockGrid = float2(blockDensity * ReShade::AspectRatio, blockDensity);
        float2 blockUV         = floor(scanUV * blockGrid);
        float blockNoise       = FadeHash(blockUV + transitionSeed * seedScale);
        float blockFade        = saturate((currFade - blockNoise * (1.0 - fadeDuration)) / fadeDuration);
        blockFade              = (toggleMode == 1) ? 1.0 - blockFade : blockFade;

        return lerp(processedFrame, cleanFrame, blockFade);
    }
    else if (FadeStyle == 8)
    {
        const float shardDensity     = 12.0;
        const float shardScatterDist = 0.03;
        const float crackThickness   = 0.06;
        const float crackDarkness    = 0.10;
        const float fadeDuration     = 0.60;

        const float2 shardGrid = float2(shardDensity * ReShade::AspectRatio, shardDensity);
        float2 shardUV         = scanUV * shardGrid + transitionSeed * seedScale;

        float2 cellId;
        float minDist;
        float edgeDist;
        GetVoronoiCell(shardUV, cellId, minDist, edgeDist);

        float shardSeed = FadeHash(cellId + 91.7);
        float shardFade = saturate((currFade - shardSeed * (1.0 - fadeDuration)) / fadeDuration);
        shardFade       = (toggleMode == 1) ? 1.0 - shardFade : shardFade;

        float shardDir     = globalTrigger ? 1.0 : -1.0;
        float shardMotion  = 1.0 - abs(shardFade * 2.0 - 1.0);
        float2 shardOffset = (float2(FadeHash(cellId), FadeHash(cellId + 3.3)) - 0.5) * shardMotion * shardScatterDist * shardDir;
        float2 shardScanUV = scanUV + shardOffset;

        float4 shardClean     = tex2Dlod(cleanSampler,        float4(shardScanUV, 0.0, 0.0));
        float4 shardProcessed = tex2Dlod(ReShade::BackBuffer, float4(shardScanUV, 0.0, 0.0));
        float3 shardBlend     = lerp(shardProcessed.rgb, shardClean.rgb, shardFade);

        float crack = 1.0 - saturate((edgeDist - minDist) / crackThickness);
        shardBlend  = lerp(shardBlend, 0.0, crack * shardMotion * crackDarkness);

        return float4(shardBlend, baseBlend.a);
    }
    else if (FadeStyle == 9)
    {
        const float3 burnColor        = float3(1.0, 0.45, 0.08);
        const float2 burnNoiseScale   = float2(5.5, 8.5);
        const float burnNoiseSpeed    = 7.0;
        const float burnJaggedness    = 0.15;
        const float wipeSoftness      = 0.25;
        const float glowWidth         = 0.12;
        const float glowIntensity     = 1.3;

        const float3 emberColor       = float3(1.0, 0.65, 0.25);
        const float2 emberNoiseScale  = float2(1.42, 1.37);
        const float emberNoiseSpeed   = 3.0;
        const float emberBaseLag      = 0.03;
        const float emberLagRange     = 0.11;
        const float emberMaxLag       = emberBaseLag + emberLagRange;
        const float emberWidth        = 0.07;
        const float emberIntensity    = 0.7;

        const float3 sootColor        = float3(0.025, 0.03, 0.025);
        const float sootWidth         = 0.40;
        const float sootDarkness      = 0.95;

        const float frontSpeed        = 1.0 + (burnJaggedness + glowWidth + emberMaxLag + sootWidth) * 0.6;
        const float dissolveThreshold = 0.06;

        float burnNoise = FadeNoise((scanUV * burnNoiseScale) + (currFade * burnNoiseSpeed));
        float burnFront = currFade * frontSpeed - (burnJaggedness * 0.5 + glowWidth) + (burnNoise - 0.5) * burnJaggedness;
        float wipeBlend = saturate((burnFront - scanUV.x) / wipeSoftness);
        wipeBlend       = (toggleMode == 1) ? 1.0 - wipeBlend : wipeBlend;

        float edgeDist   = abs(burnFront - scanUV.x);
        float glow       = saturate(1.0 - edgeDist / glowWidth);

        float trailDir   = globalTrigger ? 1.0 : -1.0;

        float emberNoise = FadeNoise(scanUV * emberNoiseScale + currFade * emberNoiseSpeed + 41.7);
        float emberLag   = emberBaseLag + emberNoise * emberLagRange;
        float emberPos   = burnFront - emberLag * trailDir;
        float emberDist  = abs(emberPos - scanUV.x);
        float ember      = saturate(1.0 - emberDist / emberWidth);

        float sootDist   = (emberPos - scanUV.x) * trailDir;
        float soot       = saturate(1.0 - sootDist / sootWidth) * step(0.0, sootDist);

        float burnDissolve = saturate(min(currFade, 1.0 - currFade) / dissolveThreshold);

        float3 wiped  = lerp(processedFrame.rgb, cleanFrame.rgb, wipeBlend);
        float3 burned = saturate(wiped + burnColor * glow * glow * glowIntensity);
        burned        = saturate(burned + emberColor * ember * ember * emberIntensity);
        burned        = lerp(burned, sootColor, sootDarkness * soot);
        burned        = lerp(wiped, burned, burnDissolve);

        return float4(burned, baseBlend.a);
    }
    else if (FadeStyle == 10)
    {
        const float wipeSoftness = 0.10;

        float wipeBlend = saturate((currFade * (1.0 + wipeSoftness) - scanUV.y) / wipeSoftness);
        wipeBlend       = (toggleMode == 1) ? 1.0 - wipeBlend : wipeBlend;

        return lerp(processedFrame, cleanFrame, wipeBlend);
    }
    else
    {
        const float circleSoftness = 0.05;

        const float maxDist    = length(float2(0.5 * ReShade::AspectRatio, 0.5));
        const float circleEdge = maxDist * circleSoftness;

        float2 centered   = scanUV - 0.5;
        centered.x       *= ReShade::AspectRatio;
        float dist        = length(centered);
        float circleBlend = saturate((currFade * (maxDist + circleEdge) - dist) / circleEdge);
        circleBlend       = (toggleMode == 1) ? 1.0 - circleBlend : circleBlend;

        return lerp(processedFrame, cleanFrame, circleBlend);
    }
}

// ==================================== DEBUG & DIAGNOSTICS =====================================

void ShowDebugLayer(inout float3 color, float2 scanUV, float4 currState1)
{
    [branch]
    if (!ShowDebugTint && !ShowScanPoints
#if DEVELOPER_MODE == 1
                       && !ShowDiagnostics
#endif
       )
    {
        return;
    }

    float currFade     = currState1.r;
    float detectedTime = currState1.g;

#if DEVELOPER_MODE == 1
    [branch]
    if (ShowDiagnostics)
    {

        const float3 debugBase  = float3(0.2, 0.5, 0.8);
        const float edgeAmplify = 50.0;

        const float2 pixelSize = BUFFER_PIXEL_SIZE;
        float p00 = GetStableDepth(scanUV);
        float p01 = GetStableDepth(scanUV + float2(pixelSize.x, 0.0));
        float p10 = GetStableDepth(scanUV + float2(0.0, pixelSize.y));
        float p11 = GetStableDepth(scanUV + pixelSize);

        float gx = p00 - p11;
        float gy = p01 - p10;

        float debugEdge = saturate(sqrt(gx * gx + gy * gy)) * edgeAmplify;
        color = (0.25 * color) + (0.25 * debugBase * debugEdge) + (0.25 * debugBase);

        float2 screenPos = scanUV * BUFFER_SCREEN_SIZE;
        float tOut = 0.0;

        #if __RENDERER__ >= 0xa000
        if (screenPos.x < 640.0 && screenPos.y < 280.0)
        {
            const float fontHeader  = 24.0;
            const float fontTable   = 16.0;
            const float colWidth    = 200.0;
            const float colOffset   = 150.0;
            const float groupIndent = 10.0;

            const float2 headerPos  = float2(20.0, 20.0);
            const float2 tablePos   = headerPos + float2(0.0, fontHeader + 10.0);
            float2 col1             = tablePos;
            float2 col2             = tablePos + float2(colWidth, 0.0);
            float2 col3             = tablePos + float2(colWidth * 2.3, 0.0);

            bool globalTrigger      = currState1.b;
            float colorDiffEMA      = currState1.a;

            float4 currState2       = tex2Dlod(Samp_StateCurr2, float4(0.5, 0.5, 0.0, 0.0));
            float depthDeltaEMA     = currState2.r;

            float4 currState3       = tex2Dlod(Samp_StateCurr3, float4(0.5, 0.5, 0.0, 0.0));
            float debugPackedData   = currState3.r;
            float detectedSectors   = floor(debugPackedData / 8.0);
            float debugPackedFlags  = debugPackedData - (detectedSectors * 8.0);
            float colorAnchor       = floor(debugPackedFlags * 0.25);
            float colorTrigger      = floor((debugPackedFlags - colorAnchor * 4.0) * 0.5);
            float depthTrigger      = debugPackedFlags - (colorAnchor * 4.0) - (colorTrigger * 2.0);
            float rawMinDepth       = currState3.g;
            float rawMaxDepth       = currState3.b;
            float releaseStepMs     = currState3.a;

            float requiredTime      = TriggerBuffer + DelayBuffer;
            float currFPS           = 1000.0 / max(0.1, FrameTime);

            #define _DTR(pos, xOff, step, length, prec, val, ...) \
                { int _s[length] = { __VA_ARGS__ }; \
                DrawText_String(pos, fontTable, 1, scanUV, _s, length, tOut); } \
                DrawText_Digit(pos + float2(xOff, 0.0), fontTable, 1, scanUV, prec, val, tOut); \
                pos.y += step;
            #define ROW(col, length, p, v, ...) _DTR(col, colOffset, fontTable, length, p, v, __VA_ARGS__)

            { int s[5] = { __D, __E, __B, __U, __G };
            DrawText_String(headerPos, fontHeader, 1, scanUV, s, 5, tOut); }

            if (UseFadeTransition)
            {
                ROW(col1, 9, -1, FadeSpeed, __F,__a,__d,__e,__S,__p,__e,__e,__d);
                col1.y += groupIndent;
            }

            ROW(col1, 10, -1, PointsGrid, __P,__o,__i,__n,__t,__s,__G,__r,__i,__d);
            ROW(col1,  9, -1, SensLevel, __S,__e,__n,__s,__L,__e,__v,__e,__l);
            ROW(col1, 13, -1, TriggerBuffer, __T,__r,__i,__g,__g,__e,__r,__B,__u,__f,__f,__e,__r);
            ROW(col1, 11, -1, DelayBuffer, __D,__e,__l,__a,__y,__B,__u,__f,__f,__e,__r);
            ROW(col1, 12, -1, ReleaseSpeed, __R,__e,__l,__e,__a,__s,__e,__S,__p,__e,__e,__d);
            col1.y += groupIndent;

            if (UseColorDetection)
            {
                ROW(col1, 14, -1, ColorTolerance, __C,__o,__l,__o,__r,__T,__o,__l,__e,__r,__a,__n,__c,__e);
                ROW(col1, 15, -1, RequiredPercent, __R,__e,__q,__u,__i,__r,__e,__d,__P,__e,__r,__c,__e,__n,__t);
            }

            ROW(col2, 11,  6, rawMinDepth, __r,__a,__w,__M,__i,__n,__D,__e,__p,__t,__h);
            ROW(col2, 11,  6, rawMaxDepth, __r,__a,__w,__M,__a,__x,__D,__e,__p,__t,__h);
            ROW(col2, 13,  6, depthDeltaEMA, __d,__e,__p,__t,__h,__D,__e,__l,__t,__a,__E,__M,__A);
            col2.y += groupIndent;

            ROW(col2, 11, -1, releaseStepMs, __r,__e,__l,__e,__a,__s,__e,__S,__t,__e,__p);
            ROW(col2, 12, -1, round(detectedTime), __d,__e,__t,__e,__c,__t,__e,__d,__T,__i,__m,__e);
            ROW(col2, 12, -1, requiredTime, __r,__e,__q,__u,__i,__r,__e,__d,__T,__i,__m,__e);
            ROW(col2, 12, -1, depthTrigger, __d,__e,__p,__t,__h,__T,__r,__i,__g,__g,__e,__r);
            ROW(col2, 13, -1, globalTrigger, __g,__l,__o,__b,__a,__l,__T,__r,__i,__g,__g,__e,__r);
            ROW(col2,  8,  3, currFade, __c,__u,__r,__r,__F,__a,__d,__e);
            col2.y += groupIndent;

            if (UseColorDetection)
            {
                ROW(col2, 12, -1, colorTrigger, __c,__o,__l,__o,__r,__T,__r,__i,__g,__g,__e,__r);
                ROW(col2, 11, -1, colorAnchor, __c,__o,__l,__o,__r,__A,__n,__c,__h,__o,__r);
                ROW(col2, 12,  1, colorDiffEMA, __c,__o,__l,__o,__r,__D,__i,__f,__f,__E,__M,__A);
                ROW(col2, 15, -1, detectedSectors, __d,__e,__t,__e,__c,__t,__e,__d,__S,__e,__c,__t,__o,__r,__s);
            }

            ROW(col3,  3, -1, __RENDERER__, __A,__P,__I);
            col3.y += groupIndent;

            ROW(col3, 11, -1, BUFFER_COLOR_FORMAT, __C,__o,__l,__o,__r,__F,__o,__r,__m,__a,__t);
            ROW(col3, 10, -1, BUFFER_COLOR_SPACE, __C,__o,__l,__o,__r,__S,__p,__a,__c,__e);
            ROW(col3,  9, -1, BUFFER_COLOR_BIT_DEPTH, __C,__o,__l,__o,__r,__B,__i,__t,__s);
            ROW(col3, 11, -1, DepthBufferReady, __D,__e,__p,__t,__h,__B,__u,__f,__f,__e,__r);
            col3.y += groupIndent;

            ROW(col3,  3, -1, round(currFPS), __F,__P,__S);
            ROW(col3, 11, -1, BUFFER_WIDTH, __R,__e,__n,__d,__e,__r,__W,__i,__d,__t,__h);
            ROW(col3, 12, -1, BUFFER_HEIGHT, __R,__e,__n,__d,__e,__r,__H,__e,__i,__g,__h,__t);

            #undef ROW
            #undef _DTR
        }
        #endif

        color = lerp(color, 1.0, tOut);

        const float thumbCount   = 3.0;
        const float thumbScale   = 4.0;
        const float thumbBorder  = 2.0;
        const float thumbGap     = 2.0;
        const float thumbMargin  = 10.0;
        const float deltaAmplify = 5.0;

        const float2 thumbDim  = float2(MAX_COLS, MAX_ROWS) * thumbScale;
        const float2 thumbStep = float2(thumbDim.x + thumbGap, 0.0);
        float2 thumbPos        = BUFFER_SCREEN_SIZE - float2(thumbDim.x * thumbCount + thumbGap *
                                 (thumbCount - 1.0) + thumbMargin, thumbDim.y + thumbMargin);

        float2 uv;

        if (GetThumbUV(screenPos, thumbPos, thumbDim, thumbBorder, uv, color))
        {
            float depth = tex2Dlod(Samp_DepthPrev, float4(uv, 0.0, 0.0)).r;
            color       = depth.xxx;
        }

        thumbPos += thumbStep;

        if (GetThumbUV(screenPos, thumbPos, thumbDim, thumbBorder, uv, color))
        {
            color = tex2Dlod(Samp_ColorSnap, float4(uv, 0.0, 0.0)).rgb;
        }

        thumbPos += thumbStep;

        if (GetThumbUV(screenPos, thumbPos, thumbDim, thumbBorder, uv, color))
        {
            float3 live = tex2Dlod(Samp_ColorLive, float4(uv, 0.0, 0.0)).rgb;
            float3 snap = tex2Dlod(Samp_ColorSnap, float4(uv, 0.0, 0.0)).rgb;
            color       = saturate(abs(live - snap) * deltaAmplify);
        }
    }
#endif


    const float3 tintColor  = float3(1.0, 0.0, 0.0);
    const float tintOpacity = 0.3;

    if (ShowDebugTint && currFade > 0.0001)
    {
        color = lerp(color, tintColor, tintOpacity * currFade);
    }

    [branch]
    if (ShowScanPoints)
    {
        const float3 dotColorActive = float3(1.0, 1.0, 0.0);
        const float3 dotColorStatic = float3(0.0, 0.5, 1.0);
        const float dotSize         = max(1.0, round(BUFFER_HEIGHT / 720.0));

        int gridIndex   = clamp(PointsGrid, 0, 3);
        float2 gridGaps = float2(GridColsTable[gridIndex] - 1.0, GridRowsTable[gridIndex] - 1.0);

        float2 nearestIndex = clamp(round(((scanUV - GridMargin) / GridArea) * gridGaps), 0.0, gridGaps);
        float2 targetUV     = CalcScanPointUV((uint)nearestIndex.x, (uint)nearestIndex.y, PointsGrid);
        float2 distPixels   = abs(scanUV - targetUV) * BUFFER_SCREEN_SIZE;

        if (all(distPixels < dotSize))
        {
            color = dotColorActive;

            if (UseColorDetection && detectedTime >= TriggerBuffer)
            {
                color = dotColorStatic;
            }
        }
    }
}

// ==================================== SHADER ENTRY POINTS =====================================

void PS_FetchDepth(float4 pixelScreenPos : SV_Position, float2 scanUV : TEXCOORD, out float outDepth : SV_Target)
{
    int gridIndex = clamp(PointsGrid, 0, 3);
    uint col = (uint)pixelScreenPos.x;
    uint row = (uint)pixelScreenPos.y;

    [branch]
    if (col < GridColsTable[gridIndex] && row < GridRowsTable[gridIndex])
    {
        outDepth = GetStableDepth(CalcScanPointUV(col, row, PointsGrid));
    }
    else
    {
        outDepth = 0.0;
    }
}

void PS_FetchColorLive(float4 pixelScreenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    if (!UseColorDetection)
    {
        outColor = 0.0;
        return;
    }

    uint col = (uint)pixelScreenPos.x;
    uint row = (uint)pixelScreenPos.y;
    float2 targetUV = CalcScanPointUV(col, row, 3);

    float3 rgb = tex2Dlod(ReShade::BackBuffer, float4(targetUV, 0.0, 0.0)).rgb;

    #if (USE_HDR_SUPPORT == 1 && BUFFER_COLOR_SPACE == 2)
        rgb = rgb / (1.0 + max(rgb, 0.0));
    #endif

    outColor = float4(saturate(rgb), 1.0);
}

void PS_AnalyzeCache(float4 pixelScreenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outStateCurr1 : SV_Target0,
                                                                                    out float4 outStateCurr2 : SV_Target1
#if DEVELOPER_MODE == 1
                                                                                  , out float4 outStateCurr3 : SV_Target2
#endif
                    )
{

    [branch]
    if (FrameCount < StartupFrames)
    {
        outStateCurr1 = float4(1.0, TriggerBuffer + DelayBuffer, 1.0, 0.0);
        outStateCurr2 = float4(0.0, 0.0, 0.0, 0.0);

        return;
    }

    float4 prevState1 = tex2Dlod(Samp_StatePrev1, float4(0.5, 0.5, 0.0, 0.0));
    float4 prevState2 = tex2Dlod(Samp_StatePrev2, float4(0.5, 0.5, 0.0, 0.0));
    float currFade      = prevState1.r;
    float detectedTime  = prevState1.g;
    bool globalTrigger  = prevState1.b;
    float colorDiffEMA  = prevState1.a;
    float depthDeltaEMA = prevState2.r;

    int gridIndex = clamp(PointsGrid, 0, 3);
    float sensMultiplier = SensBoostTable[clamp(SensLevel - 1, 0, 4)];

    float maxDepthDelta = 0.0;
    bool depthBreak = false;

    [loop]
    for (uint y = 0; y < GridRowsTable[gridIndex]; y++)
    {
        [loop]
        for (uint x = 0; x < GridColsTable[gridIndex]; x++)
        {
            float2 pointUV = float2((x + 0.5) * InvMaxCols, (y + 0.5) * InvMaxRows);

            float currDepth  = tex2Dlod(Samp_DepthCurr, float4(pointUV, 0.0, 0.0)).r;
            float prevDepth  = tex2Dlod(Samp_DepthPrev, float4(pointUV, 0.0, 0.0)).r;
            float depthDelta = abs(currDepth - prevDepth) * sensMultiplier;

            if (depthDelta > LowerThreshold)
            {
                maxDepthDelta = depthDelta;
                depthBreak = true;
                break;
            }
            else
            {
                maxDepthDelta = max(maxDepthDelta, depthDelta);
            }
        }
        if (depthBreak)
        {
            break;
        }
    }

    if (maxDepthDelta < depthDeltaEMA)
    {
        depthDeltaEMA = maxDepthDelta;
    }
    else
    {
        depthDeltaEMA = lerp(depthDeltaEMA, maxDepthDelta, DepthSmoothAlpha);
    }

#if DEVELOPER_MODE == 1
    float rawMinDepth = 1.0;
    float rawMaxDepth = 0.0;

    [loop]
    for (uint y = 0; y < GridRowsTable[gridIndex]; y++)
    {
        [loop]
        for (uint x = 0; x < GridColsTable[gridIndex]; x++)
        {
            float2 pointUV  = float2((x + 0.5) * InvMaxCols, (y + 0.5) * InvMaxRows);
            float currDepth = tex2Dlod(Samp_DepthCurr, float4(pointUV, 0.0, 0.0)).r;
            rawMinDepth = min(rawMinDepth, currDepth);
            rawMaxDepth = max(rawMaxDepth, currDepth);
        }
    }
#endif

    float changedPercent  = 0.0;
    float detectedSectors = 0.0;
    bool colorAnchor = false;

    float colorWakeupTime = max(0.0, TriggerBuffer - ColorWakeupOffsetMs);

    bool colorSnapGate = (detectedTime <= -SnapshotCooldownMs + 0.1);
    colorDiffEMA = (colorSnapGate) ? 0.0 : colorDiffEMA;

    [branch]
    if (UseColorDetection
#if DEVELOPER_MODE != 1
        && (globalTrigger || detectedTime >= colorWakeupTime)
#endif
       )
    {
        float2 colorResult = GetColorJumpPercent();
        changedPercent  = colorResult.x;
        detectedSectors = colorResult.y;

        colorDiffEMA = lerp(colorDiffEMA, changedPercent, ColorSmoothAlpha);
    }

    if (UseColorDetection && globalTrigger && changedPercent > 0.0)
    {
        float anchorFactor = lerp(1.0, 0.5, saturate(RequiredPercent / 50.0));
        colorAnchor = changedPercent < (RequiredPercent * anchorFactor);
    }

    float frameTimeMs   = clamp(FrameTime, 0.5, 50.0);
    float requiredTime  = TriggerBuffer + DelayBuffer;

    float releaseFactor = (0.008 * ReleaseSpeed + 0.006) + 3.5 * pow(0.36, 11.0 - ReleaseSpeed);
    float releaseStepMs = requiredTime * releaseFactor * (frameTimeMs / 16.67);

    float scaledUpperThreshold = UpperThreshold * sensMultiplier;

    if (depthDeltaEMA < LowerThreshold && !colorAnchor)
    {
        if (detectedTime < 0.0)
        {
            detectedTime = frameTimeMs;
        }
        else
        {
            detectedTime = min(detectedTime + frameTimeMs, requiredTime);
        }
    }
    else if (depthDeltaEMA < scaledUpperThreshold)
    {
        if (detectedTime > 0.0)
        {
            detectedTime = max(detectedTime - releaseStepMs, 0.0);
        }
        else
        {
            detectedTime = max(detectedTime - frameTimeMs, -SnapshotCooldownMs);
        }
    }

    bool depthTrigger = (detectedTime >= TriggerBuffer);
    bool colorTrigger = (colorDiffEMA >= RequiredPercent && detectedSectors >= SECTOR_REQUIRED);

    if (depthTrigger)
    {
        if (!UseColorDetection || colorTrigger)
        {
            globalTrigger = true;
        }
    }
    else if (detectedTime <= 0.0)
    {
        globalTrigger = false;
    }

    if (!UseFadeTransition)
    {
        currFade = globalTrigger;
    }
    else
    {
        float fadeFactor = saturate((frameTimeMs / 16.67) / lerp(30.0, 1.0, FadeSpeed * (0.9 / 10.0)));
        currFade = lerp(currFade, globalTrigger, fadeFactor);
        currFade = (abs(currFade - globalTrigger) < 0.00001) ? globalTrigger : currFade;
    }

    outStateCurr1 = float4(currFade, detectedTime, globalTrigger, colorDiffEMA);
    outStateCurr2 = float4(depthDeltaEMA, 0.0, 0.0, 0.0);

#if DEVELOPER_MODE == 1
    float debugPackedFlags = depthTrigger + (colorTrigger * 2.0) + (colorAnchor ? 4.0 : 0.0);
    float debugPackedData  = debugPackedFlags + detectedSectors * 8.0;
    outStateCurr3 = float4(debugPackedData, rawMinDepth, rawMaxDepth, releaseStepMs);
#endif
}

void PS_SyncState(float4 pixelScreenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outStatePrev1 : SV_Target0,
                                                                                 out float4 outStatePrev2 : SV_Target1)
{
    outStatePrev1 = tex2Dlod(Samp_StateCurr1, float4(0.5, 0.5, 0.0, 0.0));
    outStatePrev2 = tex2Dlod(Samp_StateCurr2, float4(0.5, 0.5, 0.0, 0.0));
}

void PS_UpdateDepth(float4 pixelScreenPos : SV_Position, float2 scanUV : TEXCOORD, out float outDepth : SV_Target)
{
    int gridIndex = clamp(PointsGrid, 0, 3);
    uint col = (uint)pixelScreenPos.x;
    uint row = (uint)pixelScreenPos.y;

    [branch]
    if (col < GridColsTable[gridIndex] && row < GridRowsTable[gridIndex])
    {
        outDepth = tex2Dlod(Samp_DepthCurr, float4(scanUV, 0.0, 0.0)).r;
    }
    else
    {
        outDepth = 0.0;
    }
}

void PS_UpdateColorCurr(float4 pixelScreenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColorCurr : SV_Target)
{
    if (!UseColorDetection)
    {
        outColorCurr = 0.0;
        return;
    }

    float detectedTime = tex2Dlod(Samp_StateCurr1, float4(0.5, 0.5, 0.0, 0.0)).g;

    bool colorSnapGate = (detectedTime <= -SnapshotCooldownMs + 0.1);

    [branch]
    if (FrameCount < StartupFrames)
    {
        outColorCurr = 1.0;
    }
    else if (colorSnapGate)
    {
        outColorCurr = tex2Dlod(Samp_ColorLive, float4(scanUV, 0.0, 0.0));
    }
    else
    {
        outColorCurr = tex2Dlod(Samp_ColorSnap, float4(scanUV, 0.0, 0.0));
    }
}

void PS_UpdateColorSnap(float4 pixelScreenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColorSnap : SV_Target)
{
    if (!UseColorDetection)
    {
        outColorSnap = 0.0;
        return;
    }
    outColorSnap = tex2Dlod(Samp_ColorCurr, float4(scanUV, 0.0, 0.0));
}

void PS_SaveBackBuffer(float4 pixelScreenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    outColor = tex2Dlod(ReShade::BackBuffer, float4(scanUV, 0.0, 0.0));
}

void VS_ApplyEarlyOut(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
{
    position = ProcessVertexKill(id, ToggleMode1, texcoord);
}

#if NUM_TECH_PAIRS == 2
void VS_ApplyEarlyOut2(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
{
    position = ProcessVertexKill(id, ToggleMode2, texcoord);
}
#endif

void PS_ApplyToggle(float4 pixelScreenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    float4 currState1  = tex2Dlod(Samp_StateCurr1, float4(0.5, 0.5, 0.0, 0.0));
    float currFade     = currState1.r;
    bool globalTrigger = currState1.b;

    outColor = BlendToggle(Samp_Clean, scanUV, currFade, ToggleMode1, globalTrigger);

    ShowDebugLayer(outColor.rgb, scanUV, currState1);
}

#if NUM_TECH_PAIRS == 2
void PS_ApplyToggle2(float4 pixelScreenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    float4 currState1  = tex2Dlod(Samp_StateCurr1, float4(0.5, 0.5, 0.0, 0.0));
    float currFade     = currState1.r;
    bool globalTrigger = currState1.b;

    outColor = BlendToggle(Samp_Clean2, scanUV, currFade, ToggleMode2, globalTrigger);
}
#endif

}

// ========================================= TECHNIQUES =========================================

technique StaticDepth_Detect <
    ui_tooltip = "Core Detection -> Place at the VERY TOP.";
>
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_FetchDepth;      RenderTarget  = StaticDetect::Tex_DepthCurr; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_FetchColorLive;  RenderTarget  = StaticDetect::Tex_ColorLive; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_AnalyzeCache;    RenderTarget0 = StaticDetect::Tex_StateCurr1;
                                                                                         RenderTarget1 = StaticDetect::Tex_StateCurr2;
#if DEVELOPER_MODE == 1
                                                                                         RenderTarget2 = StaticDetect::Tex_StateCurr3;
#endif
         }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_SyncState;       RenderTarget0 = StaticDetect::Tex_StatePrev1; 
                                                                                         RenderTarget1 = StaticDetect::Tex_StatePrev2; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_UpdateDepth;     RenderTarget  = StaticDetect::Tex_DepthPrev; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_UpdateColorCurr; RenderTarget  = StaticDetect::Tex_ColorCurr; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_UpdateColorSnap; RenderTarget  = StaticDetect::Tex_ColorSnap; }
}

technique StaticDepth_Before <
    ui_tooltip = "Gate In -> Place BEFORE desired effects.";
>
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_SaveBackBuffer;  RenderTarget  = StaticDetect::Tex_Clean; }
}

#if NUM_TECH_PAIRS == 2
technique StaticDepth_Before_2 <
    ui_tooltip = "Gate In -> Place BEFORE desired effects.";
>
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_SaveBackBuffer;  RenderTarget  = StaticDetect::Tex_Clean2; }
}
#endif

technique StaticDepth_After <
    ui_tooltip = "Gate Out -> Place AFTER desired effects.";
>
{
    pass { VertexShader = StaticDetect::VS_ApplyEarlyOut;  PixelShader = StaticDetect::PS_ApplyToggle; }
}

#if NUM_TECH_PAIRS == 2
technique StaticDepth_After_2 <
    ui_tooltip = "Gate Out -> Place AFTER desired effects.";
>
{
    pass { VertexShader = StaticDetect::VS_ApplyEarlyOut2; PixelShader = StaticDetect::PS_ApplyToggle2; }
}
#endif
