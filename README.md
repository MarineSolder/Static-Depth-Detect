<h1>Static Depth Detect</h1>
<p>
  <strong>Version:</strong> 0.3b<br>
  <strong>Author:</strong> MarineSolder © 2026<br>
  <strong>License:</strong> Proprietary<br>
</p>
<hr>
<h2>The Problem</h2>
<p>
  In many legacy titles, the 3D scene completely freezes during Menu navigation or FMV (video) playback. Advanced <strong>ReShade</strong> depth-based shaders (like Bloom, Ambient Occlusion or Ray Casting) often can't detect these transitions because they are not designed for such a task. This leads to significant visual artifacts:
</p>
<ul>
  <li><strong>Bloom Overlays:</strong> Intense light bleeding that distorts the UI and menu elements.</li>
  <li><strong>Ambient Occlusion/Shadowing:</strong> Shader-generated shadows appearing "on top" of FMV sequences or Menu items.</li>
</ul>

<h2>The Solution: Static Depth Detection</h2>
<p>
  This shader tries to detect the scene's depth state through a scan points system with extreme precision and functions as a trigger to automatically toggle desired effects off/on when 3D rendering freezes.
</p>

<h2>Requirements</h2>
<ul>
  <li><strong>ReShade:</strong> 5.0 or higher.</li>
  <li><strong>Anti-Aliasing:</strong> Disable MSAA in game settings for depth detection to work.</li>
  <li><strong>Generic Depth:</strong> Depth Addon must be enabled in ReShade's settings.</li>
  <li><strong>Depth Input:</strong> The depth input must have the correct polarity (RESHADE_DEPTH_INPUT_IS_REVERSED) to track depth state changes.</li>
  
