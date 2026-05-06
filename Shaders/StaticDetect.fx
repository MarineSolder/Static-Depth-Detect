// -----------------------------------------------------------------------------
//  Shader name:  Static Depth Detect
// -----------------------------------------------------------------------------
//  Version:      0.6a
//  Author:       MarineSolder © 2026
//  License:      Proprietary
//  Source:       https://github.com/MarineSolder/Static-Depth-Detect
// -----------------------------------------------------------------------------
//  Requirements & Limitations:
//   - ReShade: 5.0 or higher
//   - Graphics API: DirectX 9.0c, 10, 11 (Others - not yet fully tested).
//   - Anti-Aliasing: Disable MSAA in game settings for depth detection to work.
//   - Generic Depth: Depth Addon must be enabled in ReShade's settings.
//   - Depth Input: The depth input must have the correct polarity
//     (RESHADE_DEPTH_INPUT_IS_REVERSED) to track depth state changes properly.
// -----------------------------------------------------------------------------

#include "ReShade.fxh"

#if DEVELOPER_MODE == 1
    #include "DrawText.fxh"
#endif

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

#if USE_HDR_SUPPORT == 1
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

static const uint GridColsTable[4]    = { 6, 12, 24, 60 };
static const uint GridRowsTable[4]    = { 4, 8, 16, 40 };

static const float GridMargin         = 0.05f;
static const float GridArea           = 0.90f;

static const float SensBoostTable[5]  = { 1.0f, 10.0f, 100.0f, 1000.0f, 10000.0f };
static const float thresholdEntry     = 0.0001f;
static const float thresholdExit      = 0.0002f;

uniform float FrameTime < source = "frametime"; >;

#if DEVELOPER_MODE == 1
uniform bool BufDepth < source = "bufready_depth"; >;
#endif

uniform int Info <
    ui_category = "Info";
    ui_category_closed = true;
    ui_label    = " ";
    ui_type     = "radio";
    ui_text     = "Shader: Static Depth Detect v0.6a\n"
                  "Author: MarineSolder © 2026\n\n"
                  "In many legacy titles, the 3D scene completely freezes during Menu navigation or FMV playback.\n"
                  "This shader detects depth freeze and automatically toggles off/on desired effects to prevent interference with Menu or FMV.\n\n"
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
    ui_tooltip  = "Choose scan-point density to suit different gameplay situations.";
> = 1;

uniform int SensFrames <
    ui_category = "Detection Area"; 
    ui_label    = "Number of Frames";
    ui_type     = "slider";
    ui_min      = 5; ui_max = 300; ui_step = 1;
    ui_tooltip  = "Number of frames the Depth must remain static to activate Trigger.";
> = 30;

uniform int SensLevel <
    ui_category = "Depth Detection"; 
    ui_label    = "Sensitivity Level";
    ui_type     = "slider";
    ui_min      = 1; ui_max = 5; ui_step = 1;
    ui_tooltip  = "Multiplier for Depth sensitivity. 1 - Lazy detection, 5 - Aggressive detection.";
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
    ui_min      = 1; ui_max = 10; ui_step = 1;
    ui_tooltip  = "Reset speed of the Trigger Buffer. 1 - Slow reset, 10 - Instant reset.";
> = 9;

uniform bool ColorDetection <
    ui_category = "Color Detection";
    ui_label    = "Enable Color-Jump Detection";
    ui_tooltip  = "This may improve or break global detection accuracy, depending on the game.\n"
                  "OFF - Uses Depth detection only, ON - Adds color change monitoring of the scene to protect Trigger stability.";
> = false;

uniform int ColorTolerance <
    ui_category = "Color Detection"; 
    ui_label    = "Tolerance (%)";
    ui_type     = "slider";
    ui_min      = 1; ui_max = 40; ui_step = 1;
    ui_tooltip  = "Minimum color difference required for a pixel to be considered as \"changed\".";
> = 8;

uniform int RequiredPercent <
    ui_category = "Color Detection"; 
    ui_label    = "Required Change (%)";
    ui_type     = "slider";
    ui_min      = 1; ui_max = 90; ui_step = 1;
    ui_tooltip  = "Required percentage of changed pixels to confirm the \"color-jump\".";
> = 15;

uniform bool ShowDebugTint < 
    ui_category = "Debug"; 
    ui_label    = "Show Trigger Overlay (Red Tint)"; 
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

texture MS_TexColorLive { Width = MAX_COLS; Height = MAX_ROWS; Format = RGBA8; };
texture MS_TexColorCurr { Width = MAX_COLS; Height = MAX_ROWS; Format = RGBA8; };
texture MS_TexColorPrev { Width = MAX_COLS; Height = MAX_ROWS; Format = RGBA8; };
sampler MS_SampColorLive { Texture = MS_TexColorLive; SRGBTexture = false; };
sampler MS_SampColorCurr { Texture = MS_TexColorCurr; SRGBTexture = false; };
sampler MS_SampColorPrev { Texture = MS_TexColorPrev; SRGBTexture = false; };

#if DEVELOPER_MODE == 1
texture MS_TexDebug { Width = 1; Height = 1; Format = RGBA32F; };
sampler MS_SampDebug { Texture = MS_TexDebug; };
#endif

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

    float denomDepth = max(0.000001f, farPlane - (depth * planeRange));
    depth /= denomDepth;

    return saturate(depth);
}

float2 CalcScanPointUV(const uint col, const uint row, const int mode)
{
    const int gridIndex = clamp(mode, 0, 3);
    const float2 gridGaps = float2((float)GridColsTable[gridIndex] - 1.0f, 
                                   (float)GridRowsTable[gridIndex] - 1.0f);

    return float2(GridMargin + ((float)col / gridGaps.x) * GridArea, 
                  GridMargin + ((float)row / gridGaps.y) * GridArea);
}

float GetColorJumpPercent()
{
    float changedPixels = 0.0f;
    const float sqColorTolerance = (ColorTolerance / 100.0f) * (ColorTolerance / 100.0f);

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
    return (changedPixels / MaxScanPoints) * 100.0f;
}

// ------- DEBUG & DIAGNOSTICS -------

void ShowDebugLayer(inout float3 color, float2 scanUV, float4 currState)
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

    const float currentFade = currState.r;

#if DEVELOPER_MODE == 1
    if (ShowDiagnostics)
    {
        const float2 pixelSize = BUFFER_PIXEL_SIZE;
        float p00 = FetchLinearDepth(scanUV);
        float p01 = FetchLinearDepth(scanUV + float2(pixelSize.x, 0.0f));
        float p10 = FetchLinearDepth(scanUV + float2(0.0f, pixelSize.y));
        float p11 = FetchLinearDepth(scanUV + pixelSize);
        float gx = p00 - p11;
        float gy = p01 - p10;
        float debugEdge = saturate(sqrt(gx * gx + gy * gy)) * 50.0f;

        const float3 debugBase = float3(0.2f, 0.5f, 0.8f);
        float3 depthOverlay = lerp(lerp(color * 0.7f, debugBase * debugEdge, 0.5f), debugBase, 0.5f);

        const float2 screenPos = scanUV * BUFFER_SCREEN_SIZE;
        float tOut = 0.0f;

#if __RENDERER__ >= 0xa000
        if (screenPos.x < 640.0f && screenPos.y < 240.0f)
        {
            float4 debugData = tex2Dlod(MS_SampDebug, float4(0.5f, 0.5f, 0.0f, 0.0f));
            float maxDepthDelta     = debugData.r;
            float releaseStep       = debugData.g;
            float currentThreshold  = debugData.b;
            float changedPercent    = debugData.a;
            float frameCount        = currState.g;
            float globalTrigger     = currState.b;
            float depthTrigger      = (frameCount >= (float)SensFrames) ? 1.0f : 0.0f;
            float colorTrigger      = (changedPercent >= (float)RequiredPercent) ? 1.0f : 0.0f;
            const float requiredFrames = (float)(SensFrames + DelayFrames);
            float currentFPS        = 1000.0f / max(0.1f, FrameTime);

            const float fontHeader  = 24.0f;
            const float fontTable   = 16.0f;
            const float colWidth    = 210.0f;
            const float col1Offset  = 155.0f;
            const float col2Offset  = 155.0f;
            const float col3Offset  = 145.0f;
            const float groupIndent = fontTable + 5.0f;

            float2 tablePos = float2(20.0f, 20.0f);

            int txt_DEBUG[5] = { __D, __E, __B, __U, __G };
            DrawText_String(tablePos, fontHeader, 1, scanUV, txt_DEBUG, 5, tOut);
            tablePos.y += fontHeader + 10.0f;

            float2 col1 = tablePos;
            float2 col2 = tablePos + float2(colWidth, 0.0f);
            float2 col3 = tablePos + float2(colWidth * 2.2f, 0.0f);

            int txt_FadeSpeed[10] = { __F, __a, __d, __e, __S, __p, __e, __e, __d, __Equals };
            DrawText_String(col1, fontTable, 1, scanUV, txt_FadeSpeed, 10, tOut);
            DrawText_Digit(col1 + float2(col1Offset, 0.0f), fontTable, 1, scanUV, 1, FadeSpeed, tOut);
            col1.y += groupIndent;

            int txt_PointsGrid[11] = { __P, __o, __i, __n, __t, __s, __G, __r, __i, __d, __Equals };
            DrawText_String(col1, fontTable, 1, scanUV, txt_PointsGrid, 11, tOut);
            DrawText_Digit(col1 + float2(col1Offset, 0.0f), fontTable, 1, scanUV, -1, (float)PointsGrid, tOut);
            col1.y += fontTable;

            int txt_SensFrames[11] = { __S, __e, __n, __s, __F, __r, __a, __m, __e, __s, __Equals };
            DrawText_String(col1, fontTable, 1, scanUV, txt_SensFrames, 11, tOut);
            DrawText_Digit(col1 + float2(col1Offset, 0.0f), fontTable, 1, scanUV, -1, (float)SensFrames, tOut);
            col1.y += fontTable;

            int txt_SensLevel[10] = { __S, __e, __n, __s, __L, __e, __v, __e, __l, __Equals };
            DrawText_String(col1, fontTable, 1, scanUV, txt_SensLevel, 10, tOut);
            DrawText_Digit(col1 + float2(col1Offset, 0.0f), fontTable, 1, scanUV, -1, (float)SensLevel, tOut);
            col1.y += fontTable;

            int txt_DelayFrames[12] = { __D, __e, __l, __a, __y, __F, __r, __a, __m, __e, __s, __Equals };
            DrawText_String(col1, fontTable, 1, scanUV, txt_DelayFrames, 12, tOut);
            DrawText_Digit(col1 + float2(col1Offset, 0.0f), fontTable, 1, scanUV, -1, (float)DelayFrames, tOut);
            col1.y += fontTable;

            int txt_ReleaseSpeed[13] = { __R, __e, __l, __e, __a, __s, __e, __S, __p, __e, __e, __d, __Equals };
            DrawText_String(col1, fontTable, 1, scanUV, txt_ReleaseSpeed, 13, tOut);
            DrawText_Digit(col1 + float2(col1Offset, 0.0f), fontTable, 1, scanUV, -1, (float)ReleaseSpeed, tOut);
            col1.y += groupIndent;

            int txt_ColorDetect[15] = { __C, __o, __l, __o, __r, __D, __e, __t, __e, __c, __t, __i, __o, __n, __Equals };
            DrawText_String(col1, fontTable, 1, scanUV, txt_ColorDetect, 15, tOut);
            DrawText_Digit(col1 + float2(col1Offset, 0.0f), fontTable, 1, scanUV, -1, (float)ColorDetection, tOut);
            col1.y += fontTable;

            if (ColorDetection)
            {
                int txt_ColorTol[15] = { __C, __o, __l, __o, __r, __T, __o, __l, __e, __r, __a, __n, __c, __e, __Equals };
                DrawText_String(col1, fontTable, 1, scanUV, txt_ColorTol, 15, tOut);
                DrawText_Digit(col1 + float2(col1Offset, 0.0f), fontTable, 1, scanUV, -1, (float)ColorTolerance, tOut);
                col1.y += fontTable;

                int txt_ReqPercent[16] = { __R, __e, __q, __u, __i, __r, __e, __d, __P, __e, __r, __c, __e, __n, __t, __Equals };
                DrawText_String(col1, fontTable, 1, scanUV, txt_ReqPercent, 16, tOut);
                DrawText_Digit(col1 + float2(col1Offset, 0.0f), fontTable, 1, scanUV, -1, (float)RequiredPercent, tOut);
            }

            int txt_Threshold[17] = { __c, __u, __r, __r, __e, __n, __t, __T, __h, __r, __e, __s, __h, __o, __l, __d, __Equals };
            DrawText_String(col2, fontTable, 1, scanUV, txt_Threshold, 17, tOut);
            DrawText_Digit(col2 + float2(col2Offset, 0.0f), fontTable, 1, scanUV, 6, currentThreshold, tOut);
            col2.y += fontTable;

            int txt_MaxDelta[14] = { __m, __a, __x, __D, __e, __p, __t, __h, __D, __e, __l, __t, __a, __Equals };
            DrawText_String(col2, fontTable, 1, scanUV, txt_MaxDelta, 14, tOut);
            DrawText_Digit(col2 + float2(col2Offset, 0.0f), fontTable, 1, scanUV, 6, maxDepthDelta, tOut);
            col2.y += groupIndent;

            int txt_ReleaseStep[12] = { __r, __e, __l, __e, __a, __s, __e, __S, __t, __e, __p, __Equals };
            DrawText_String(col2, fontTable, 1, scanUV, txt_ReleaseStep, 12, tOut);
            DrawText_Digit(col2 + float2(col2Offset, 0.0f), fontTable, 1, scanUV, 1, releaseStep, tOut);
            col2.y += fontTable;

            int txt_FrameCount[11] = { __f, __r, __a, __m, __e, __C, __o, __u, __n, __t, __Equals };
            DrawText_String(col2, fontTable, 1, scanUV, txt_FrameCount, 11, tOut);
            DrawText_Digit(col2 + float2(col2Offset, 0.0f), fontTable, 1, scanUV, -1, frameCount, tOut);
            col2.y += fontTable;

            int txt_ReqFrames[15] = { __r, __e, __q, __u, __i, __r, __e, __d, __F, __r, __a, __m, __e, __s, __Equals };
            DrawText_String(col2, fontTable, 1, scanUV, txt_ReqFrames, 15, tOut);
            DrawText_Digit(col2 + float2(col2Offset, 0.0f), fontTable, 1, scanUV, -1, requiredFrames, tOut);
            col2.y += fontTable;

            int txt_DepthTrigger[13] = { __d, __e, __p, __t, __h, __T, __r, __i, __g, __g, __e, __r, __Equals };
            DrawText_String(col2, fontTable, 1, scanUV, txt_DepthTrigger, 13, tOut);
            DrawText_Digit(col2 + float2(col2Offset, 0.0f), fontTable, 1, scanUV, -1, depthTrigger, tOut);
            col2.y += fontTable;

            int txt_GlobalTrigger[14] = { __g, __l, __o, __b, __a, __l, __T, __r, __i, __g, __g, __e, __r, __Equals };
            DrawText_String(col2, fontTable, 1, scanUV, txt_GlobalTrigger, 14, tOut);
            DrawText_Digit(col2 + float2(col2Offset, 0.0f), fontTable, 1, scanUV, -1, globalTrigger, tOut);
            col2.y += fontTable;

            int txt_CurrentFade[12] = { __c, __u, __r, __r, __e, __n, __t, __F, __a, __d, __e, __Equals };
            DrawText_String(col2, fontTable, 1, scanUV, txt_CurrentFade, 12, tOut);
            DrawText_Digit(col2 + float2(col2Offset, 0.0f), fontTable, 1, scanUV, 3, currentFade, tOut);
            col2.y += groupIndent;

            if (ColorDetection)
            {
                int txt_ColorTrigger[13] = { __c, __o, __l, __o, __r, __T, __r, __i, __g, __g, __e, __r, __Equals };
                DrawText_String(col2, fontTable, 1, scanUV, txt_ColorTrigger, 13, tOut);
                DrawText_Digit(col2 + float2(col2Offset, 0.0f), fontTable, 1, scanUV, -1, colorTrigger, tOut);
                col2.y += fontTable;

                int txt_ChangedPct[15] = { __c, __h, __a, __n, __g, __e, __d, __P, __e, __r, __c, __e, __n, __t, __Equals };
                DrawText_String(col2, fontTable, 1, scanUV, txt_ChangedPct, 15, tOut);
                DrawText_Digit(col2 + float2(col2Offset, 0.0f), fontTable, 1, scanUV, 1, changedPercent, tOut);
            }

            int txt_Renderer[4] = { __A, __P, __I, __Equals }; 
            DrawText_String(col3, fontTable, 1, scanUV, txt_Renderer, 4, tOut);
            DrawText_Digit(col3 + float2(col3Offset, 0.0f), fontTable, 1, scanUV, -1, (float)__RENDERER__, tOut);
            col3.y += groupIndent;

            int txt_ColorFormat[12] = { __C, __o, __l, __o, __r, __F, __o, __r, __m, __a, __t, __Equals };
            DrawText_String(col3, fontTable, 1, scanUV, txt_ColorFormat, 12, tOut);
            DrawText_Digit(col3 + float2(col3Offset, 0.0f), fontTable, 1, scanUV, -1, (float)BUFFER_COLOR_FORMAT, tOut);
            col3.y += fontTable;

            int txt_ColorSpace[11] = { __C, __o, __l, __o, __r, __S, __p, __a, __c, __e, __Equals };
            DrawText_String(col3, fontTable, 1, scanUV, txt_ColorSpace, 11, tOut);
            DrawText_Digit(col3 + float2(col3Offset, 0.0f), fontTable, 1, scanUV, -1, (float)BUFFER_COLOR_SPACE, tOut);
            col3.y += fontTable;

            int txt_ColorBits[10] = { __C, __o, __l, __o, __r, __B, __i, __t, __s, __Equals };
            DrawText_String(col3, fontTable, 1, scanUV, txt_ColorBits, 10, tOut);
            DrawText_Digit(col3 + float2(col3Offset, 0.0f), fontTable, 1, scanUV, -1, (float)BUFFER_COLOR_BIT_DEPTH, tOut);
            col3.y += fontTable;

            int txt_DepthBuffer[12] = { __D, __e, __p, __t, __h, __B, __u, __f, __f, __e, __r, __Equals };
            DrawText_String(col3, fontTable, 1, scanUV, txt_DepthBuffer, 12, tOut);
            DrawText_Digit(col3 + float2(col3Offset, 0.0f), fontTable, 1, scanUV, -1, BufDepth ? 1.0f : 0.0f, tOut);
            col3.y += groupIndent;

            int txt_FPS[4] = { __F, __P, __S, __Equals };
            DrawText_String(col3, fontTable, 1, scanUV, txt_FPS, 4, tOut);
            DrawText_Digit(col3 + float2(col3Offset, 0.0f), fontTable, 1, scanUV, -1, currentFPS, tOut);
            col3.y += fontTable;

            int txt_RenderWidth[12] = { __R, __e, __n, __d, __e, __r, __W, __i, __d, __t, __h, __Equals };
            DrawText_String(col3, fontTable, 1, scanUV, txt_RenderWidth, 12, tOut);
            DrawText_Digit(col3 + float2(col3Offset, 0.0f), fontTable, 1, scanUV, -1, (float)BUFFER_WIDTH, tOut);
            col3.y += fontTable;

            int txt_RenderHeight[13] = { __R, __e, __n, __d, __e, __r, __H, __e, __i, __g, __h, __t, __Equals };
            DrawText_String(col3, fontTable, 1, scanUV, txt_RenderHeight, 13, tOut);
            DrawText_Digit(col3 + float2(col3Offset, 0.0f), fontTable, 1, scanUV, -1, (float)BUFFER_HEIGHT, tOut);
            col3.y += fontTable;
        }
#endif

        color = lerp(depthOverlay, 1.0f, tOut);

        const float thumbScale  = 4.0f;
        const float thumbWidth  = (float)MAX_COLS * thumbScale;
        const float thumbHeight = (float)MAX_ROWS * thumbScale;
        const float thumbMargin = 10.0f;
        const float thumbGap    = 2.0f;
        const float borderSize  = 2.0f;

        const float2 pixelCoord = scanUV * BUFFER_SCREEN_SIZE;

        const float2 depthThumbPos = BUFFER_SCREEN_SIZE - float2((thumbWidth * 3.0f + thumbGap * 2.0f) + thumbMargin, thumbHeight + thumbMargin);
        const float2 colorSnapThumbPos = depthThumbPos + float2(thumbWidth + thumbGap, 0.0f);
        const float2 colorDeltaThumbPos = colorSnapThumbPos + float2(thumbWidth + thumbGap, 0.0f);

        const float2 depthLocal = pixelCoord - depthThumbPos;
        if (depthLocal.x >= -borderSize && depthLocal.x < thumbWidth + borderSize &&
            depthLocal.y >= -borderSize && depthLocal.y < thumbHeight + borderSize)
        {
            if (depthLocal.x < 0.0f || depthLocal.x >= thumbWidth ||
                depthLocal.y < 0.0f || depthLocal.y >= thumbHeight)
            {
                color = float3(1.0f, 1.0f, 1.0f);
            }
            else
            {
                const float2 cacheUV = depthLocal / float2(thumbWidth, thumbHeight);
                const float depthVal = tex2Dlod(MS_SampPointsPrev, float4(cacheUV, 0.0f, 0.0f)).r;
                color = float3(depthVal, depthVal, depthVal);
            }
        }

        const float2 colorSnapLocal = pixelCoord - colorSnapThumbPos;
        if (colorSnapLocal.x >= -borderSize && colorSnapLocal.x < thumbWidth + borderSize &&
            colorSnapLocal.y >= -borderSize && colorSnapLocal.y < thumbHeight + borderSize)
        {
            if (colorSnapLocal.x < 0.0f || colorSnapLocal.x >= thumbWidth ||
                colorSnapLocal.y < 0.0f || colorSnapLocal.y >= thumbHeight)
            {
                color = float3(1.0f, 1.0f, 1.0f);
            }
            else
            {
                const float2 cacheUV = colorSnapLocal / float2(thumbWidth, thumbHeight);
                color = tex2Dlod(MS_SampColorPrev, float4(cacheUV, 0.0f, 0.0f)).rgb;
            }
        }

        const float2 colorDeltaLocal = pixelCoord - colorDeltaThumbPos;
        if (colorDeltaLocal.x >= -borderSize && colorDeltaLocal.x < thumbWidth + borderSize &&
            colorDeltaLocal.y >= -borderSize && colorDeltaLocal.y < thumbHeight + borderSize)
        {
            if (colorDeltaLocal.x < 0.0f || colorDeltaLocal.x >= thumbWidth ||
                colorDeltaLocal.y < 0.0f || colorDeltaLocal.y >= thumbHeight)
            {
                color = float3(1.0f, 1.0f, 1.0f);
            }
            else
            {
                const float2 cacheUV = colorDeltaLocal / float2(thumbWidth, thumbHeight);
                const float3 cLive = tex2Dlod(MS_SampColorLive, float4(cacheUV, 0.0f, 0.0f)).rgb;
                const float3 cPrev = tex2Dlod(MS_SampColorPrev, float4(cacheUV, 0.0f, 0.0f)).rgb;
                color = saturate(abs(cLive - cPrev) * 5.0f);
            }
        }
    }
#endif

    if (ShowDebugTint && currentFade > 0.001f)
    {
        color = lerp(color, float3(1.0f, 0.0f, 0.0f), 0.3f * currentFade);
    }

    [branch]
    if (ShowScanPoints)
    {
        const int gridIndex = clamp(PointsGrid, 0, 3);
        const float2 gridGaps = float2((float)GridColsTable[gridIndex] - 1.0f, 
                                       (float)GridRowsTable[gridIndex] - 1.0f);
        const float dotSize = max(1.0f, round((float)BUFFER_HEIGHT / 720.0f));

        float2 nearestIndex = round(((scanUV - GridMargin) / GridArea) * gridGaps);
        nearestIndex = clamp(nearestIndex, 0.0f, gridGaps);

        const float2 targetUV = GridMargin + (nearestIndex / gridGaps) * GridArea;
        const float2 distPixels = abs(scanUV - targetUV) * BUFFER_SCREEN_SIZE;

        if (all(distPixels < dotSize))
        {
            float3 dotColor = float3(1.0f, 1.0f, 0.0f);

            if (ColorDetection && currState.g >= (float)SensFrames && currState.b == 0.0f)
            {
                dotColor = float3(0.0f, 0.5f, 1.0f);
            }
            color = dotColor;
        }
    }
}

// ------- SHADERS -------

void PS_FetchPoints(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float outDepth : SV_Target)
{
    const int gridIndex = clamp(PointsGrid, 0, 3);
    const uint col = (uint)screenPos.x;
    const uint row = (uint)screenPos.y;

    [branch]
    if (col < GridColsTable[gridIndex] && row < GridRowsTable[gridIndex])
    {
        outDepth = FetchLinearDepth(CalcScanPointUV(col, row, PointsGrid));
    }
    else
    {
        outDepth = 0.0f;
    }
}

void PS_FetchLiveColor(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    if (!ColorDetection)
    {
        outColor = 0.0f;
        return;
    }

    const uint col = (uint)screenPos.x;
    const uint row = (uint)screenPos.y;
    const float2 targetUV = CalcScanPointUV(col, row, 3);

    float3 rgb = tex2Dlod(ReShade::BackBuffer, float4(targetUV, 0.0f, 0.0f)).rgb;

    #if (USE_HDR_SUPPORT == 1 && BUFFER_COLOR_SPACE == 2)
        rgb = saturate(rgb / 2.54f);
    #endif

    outColor = float4(rgb, 1.0f);
}

void PS_AnalyzePoints(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outStateCurr : SV_Target0 
#if DEVELOPER_MODE == 1
                                                                              , out float4 outDebug : SV_Target1
#endif
                     )
{
    float4 prevState = tex2Dlod(MS_SampStatePrev, float4(0.5f, 0.5f, 0.0f, 0.0f));

    [branch]
    if (prevState.a < 0.5f)
    {
        prevState.r = 1.0f; prevState.g = (float)(SensFrames + DelayFrames); prevState.b = 1.0f; prevState.a = 1.0f; 
    }

    const float sensMultiplier = SensBoostTable[clamp(SensLevel - 1, 0, 4)];
    const float currentThreshold = (prevState.g > 0.0f) ? thresholdExit : thresholdEntry;

    const int gridIndex = clamp(PointsGrid, 0, 3);
    float maxDepthDelta = 0.0f;
    bool depthBreak = false;

    [loop]
    for (uint y = 0; y < GridRowsTable[gridIndex]; y++)
    {
        [loop]
        for (uint x = 0; x < GridColsTable[gridIndex]; x++)
        {
            const float2 fetchUV = float2(((float)x + 0.5f) * InvMaxCols, ((float)y + 0.5f) * InvMaxRows);

            const float depthCurr = tex2Dlod(MS_SampPointsCurr, float4(fetchUV, 0.0f, 0.0f)).r;
            const float depthPrev = tex2Dlod(MS_SampPointsPrev, float4(fetchUV, 0.0f, 0.0f)).r;
            const float depthDiff = abs(depthCurr - depthPrev) * sensMultiplier;

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

    float changedPercent = 0.0f;
    float frameCount = prevState.g;
    float globalTrigger = prevState.b;

#if DEVELOPER_MODE == 1
    [branch]
    if (ColorDetection) 
    {
        changedPercent = GetColorJumpPercent();
    }
#else
    [branch]
    if (ColorDetection && (globalTrigger == 1.0f || frameCount >= (float)SensFrames))
    {
        changedPercent = GetColorJumpPercent();
    }
#endif

    bool colorRestored = false;
    const float anchorFactor = lerp(1.0f, 0.5f, saturate((float)RequiredPercent / 50.0f));

    if (ColorDetection && frameCount > 0.0f && changedPercent < ((float)RequiredPercent * anchorFactor))
    {
        colorRestored = true;
    }

    const float requiredFrames = (float)(SensFrames + DelayFrames);
    const float timeFactor = (0.008f * (float)ReleaseSpeed + 0.006f) + 3.5f * pow(0.36f, 11.0f - (float)ReleaseSpeed);
    const float releaseStep = requiredFrames * timeFactor;

    [flatten]
    if (maxDepthDelta < currentThreshold && !colorRestored)
    {
        frameCount = min(frameCount + 1.0f, requiredFrames);
    }
    else
    {
        frameCount = max(frameCount - releaseStep, 0.0f);
    }

    const float depthTrigger = (frameCount >= (float)SensFrames) ? 1.0f : 0.0f;
    const float colorTrigger = (changedPercent >= (float)RequiredPercent) ? 1.0f : 0.0f;

    [branch]
    if (depthTrigger > 0.5f)
    {
        if (!ColorDetection)
        {
            globalTrigger = 1.0f;
        }
        else if (globalTrigger == 0.0f)
        {
            if (colorTrigger > 0.5f)
            {
                globalTrigger = 1.0f;
            }
        }
    }
    else if (frameCount <= 0.0f)
    {
        globalTrigger = 0.0f;
    }

    const float fadeFactor = saturate((FrameTime / 16.67f) / lerp(30.0f, 1.0f, FadeSpeed));
    const float currentFade = lerp(prevState.r, globalTrigger, fadeFactor);

    outStateCurr = float4(currentFade, frameCount, globalTrigger, prevState.a);
#if DEVELOPER_MODE == 1
    outDebug = float4(maxDepthDelta, releaseStep, currentThreshold, changedPercent);
#endif
}

void PS_UpdateState(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outStatePrev : SV_Target)
{
    outStatePrev = tex2Dlod(MS_SampStateCurr, float4(0.5f, 0.5f, 0.0f, 0.0f));
}

void PS_UpdatePoints(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float outDepth : SV_Target)
{
    const int gridIndex = clamp(PointsGrid, 0, 3);
    const uint col = (uint)screenPos.x;
    const uint row = (uint)screenPos.y;

    [branch]
    if (col < GridColsTable[gridIndex] && row < GridRowsTable[gridIndex])
    {
        outDepth = tex2Dlod(MS_SampPointsCurr, float4(scanUV, 0.0f, 0.0f)).r;
    }
    else
    {
        outDepth = 0.0f;
    }
}

void PS_UpdateColorCurr(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outLiveColor : SV_Target)
{
    if (!ColorDetection)
    {
        outLiveColor = 0.0f;
        return;
    }

    const float4 currState = tex2Dlod(MS_SampStateCurr, float4(0.5f, 0.5f, 0.0f, 0.0f));

    [flatten]
    if (currState.g == 0.0f)
    {
        outLiveColor = tex2Dlod(MS_SampColorLive, float4(scanUV, 0.0f, 0.0f));
    }
    else
    {
        outLiveColor = tex2Dlod(MS_SampColorPrev, float4(scanUV, 0.0f, 0.0f));
    }
}

void PS_UpdateColorPrev(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColorPrev : SV_Target)
{
    if (!ColorDetection)
    {
        outColorPrev = 0.0f;
        return;
    }
    outColorPrev = tex2Dlod(MS_SampColorCurr, float4(scanUV, 0.0f, 0.0f));
}

void PS_SaveBackBuffer(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    outColor = tex2Dlod(ReShade::BackBuffer, float4(scanUV, 0.0f, 0.0f));
}

void PS_ApplyToggle(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    const float4 currState = tex2Dlod(MS_SampStateCurr, float4(0.5f, 0.5f, 0.0f, 0.0f));
    const float currentFade = currState.r;

    const float4 cleanFrame = tex2Dlod(MS_SampClean, float4(scanUV, 0.0f, 0.0f));
    const float4 processedFrame = tex2Dlod(ReShade::BackBuffer, float4(scanUV, 0.0f, 0.0f));

    [flatten]
    if (ToggleMode1 == 0)
    {
        outColor = lerp(processedFrame, cleanFrame, currentFade);
    }
    else
    {
        outColor = lerp(cleanFrame, processedFrame, currentFade);
    }

    ShowDebugLayer(outColor.rgb, scanUV, currState);
}

#if NUM_TECH_PAIRS > 1
void PS_ApplyToggle2(float4 screenPos : SV_Position, float2 scanUV : TEXCOORD, out float4 outColor : SV_Target)
{
    const float4 currState = tex2Dlod(MS_SampStateCurr, float4(0.5f, 0.5f, 0.0f, 0.0f));
    const float currentFade = currState.r;

    const float4 cleanFrame = tex2Dlod(MS_SampClean2, float4(scanUV, 0.0f, 0.0f));
    const float4 processedFrame = tex2Dlod(ReShade::BackBuffer, float4(scanUV, 0.0f, 0.0f));

    [flatten]
    if (ToggleMode2 == 0)
    {
        outColor = lerp(processedFrame, cleanFrame, currentFade);
    }
    else
    {
        outColor = lerp(cleanFrame, processedFrame, currentFade);
    }
}
#endif

}

// ------- TECHNIQUES -------

technique StaticDepth_Detect
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_FetchPoints;     RenderTarget = StaticDetect::MS_TexPointsCurr; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_FetchLiveColor;  RenderTarget = StaticDetect::MS_TexColorLive; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_AnalyzePoints;   RenderTarget0 = StaticDetect::MS_TexStateCurr;
#if DEVELOPER_MODE == 1
                                                                                         RenderTarget1 = StaticDetect::MS_TexDebug;
#endif
         }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_UpdateState;     RenderTarget = StaticDetect::MS_TexStatePrev; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_UpdatePoints;    RenderTarget = StaticDetect::MS_TexPointsPrev; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_UpdateColorCurr; RenderTarget = StaticDetect::MS_TexColorCurr; }
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_UpdateColorPrev; RenderTarget = StaticDetect::MS_TexColorPrev; }
}

technique StaticDepth_Before
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_SaveBackBuffer; RenderTarget = StaticDetect::MS_TexClean; }
}

#if NUM_TECH_PAIRS > 1
technique StaticDepth_Before_2
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_SaveBackBuffer; RenderTarget = StaticDetect::MS_TexClean2; }
}
#endif

technique StaticDepth_After
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_ApplyToggle; }
}

#if NUM_TECH_PAIRS > 1
technique StaticDepth_After_2
{
    pass { VertexShader = PostProcessVS; PixelShader = StaticDetect::PS_ApplyToggle2; }
}
#endif
