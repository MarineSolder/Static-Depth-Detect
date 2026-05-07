<h1>Static Depth Detect</h1>
<p>
  <strong>Version:</strong> 0.6c<br>
  <strong>Author:</strong> MarineSolder © 2026<br>
  <strong>License:</strong> Proprietary<br>
</p>
<hr>
<h2>The Problem</h2>
<p>
  In many legacy titles, the 3D scene completely freezes during Menu navigation or FMV (video) playback. Advanced <strong>ReShade</strong> depth-based shaders (like Depth of Field, Ambient Occlusion or Ray Casting) can't detect these transitions because they are not designed for such a task. This leads to significant visual artifacts, such as background blur or shader-generated shadows appearing on top of FMV or Menu.
</p>

<h2>The Solution: Static Depth Detection</h2>
<p>
  This shader introduces depth state and color-jump detection through a lightweight scan-points system and functions as a trigger to automatically toggle desired effects off/on when 3D rendering freezes.
</p>

<h2>Requirements & Limitations</h2>
<ul>
  <li><strong>ReShade:</strong> 5.0 or higher.</li>
  <li><strong>Graphics API:</strong> DirectX 9.0c, 10, 11 (DirectX 12, Vulkan, OpenGL - <ins>not yet fully tested</ins>).</li>
  <li><strong>Anti-Aliasing:</strong> Disable MSAA in game settings for depth detection to work.</li>
  <li><strong>Generic Depth:</strong> Depth Addon must be enabled in ReShade's settings.</li>
  <li><strong>Depth Input:</strong> The depth input must have the correct polarity (RESHADE_DEPTH_INPUT_IS_REVERSED) to track depth state changes properly.</li>
  
