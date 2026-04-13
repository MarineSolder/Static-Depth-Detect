<h1>Static Depth Detect (Ultra-Precision)</h1>

<p>
  <strong>Version:</strong> 0.1a (Batman: Arkham Asylum version)<br>
  <strong>Author:</strong> MarineSolder © 2026<br>
  <strong>License:</strong> Proprietary<br>
</p>

<hr>

<h2>The Problem</h2>
<p>
  In many legacy titles, the 3D scene completely freezes during menu navigation or FMV (video) playback. Standard <strong>ReShade</strong> depth-based effects (like Bloom or Ambient Occlusion) often fail to detect these transitions because the depth buffer remains static but valid when the engine pauses 3D rendering for 2D overlays. This leads to significant visual artifacts:
</p>
<ul>
  <li><strong>Bloom Overlays:</strong> Intense light bleeding that distorts the UI and menu elements.</li>
  <li><strong>Ambient Occlusion/Shadowing:</strong> Shader-generated shadows appearing "on top" of 2D video sequences or menu items.</li>
</ul>

<h2>The Solution: Static Depth Detection</h2>
<p>
  This shader functions as a trigger system that monitors the scene's depth buffer state with extreme sensitivity to automatically toggle off intrusive effects when rendering freezes.
</p>
<p>
  The shader implements a <strong>scan-points system</strong> sampling specific coordinates to detect even minor pixel-level shifts in depth.
</p>

<h2>Current Implementation & Compatibility</h2>
<ul>
  <li><strong>Target Game:</strong> Currently optimized specifically for <strong>Batman: Arkham Asylum</strong>.</li>
  <li><strong>Status:</strong> Highly stable for the aforementioned title.</li>
  <li><strong>Future Plans:</strong> Looking into adapting the logic for other legacy titles where similar depth-state issues occur.</li>
</ul>

<h2>Requirements</h2>
<ul>
  <li><strong>ReShade:</strong> 5.0 or higher.</li>
  <li><strong>Generic Depth:</strong> Depth Addon must be enabled in ReShade's settings.</li>
  <li><strong>Buffer Polarity:</strong> The depth input must have the correct reading polarity (ReShade_Depth_Input_Is_Reversed) to ensure the surveillance system can accurately track scene state changes.</li>
