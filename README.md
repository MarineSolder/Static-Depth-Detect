<h1>Static Depth Detect</h1>
<p>
  <a href="https://github.com/MarineSolder/Static-Depth-Detect/archive/refs/heads/main.zip" align="right">
    <img src="https://img.shields.io/badge/Download-green?style=for-the-badge&logo=github" alt="Download" align="right">
  </a>
  <strong>Version:</strong> 0.8a<br>
  <strong>Author:</strong> MarineSolder<br>
  <strong>License:</strong> <a href="./LICENSE">Custom Non-Commercial License</a>
</p>
<hr>
<h2>The Problem</h2>
<p>
  In many legacy titles, the 3D scene completely freezes during Menu navigation or FMV (video) playback. Advanced <b>ReShade</b> depth-based shaders (like Depth of Field, Ambient Occlusion or Ray Casting) can't detect these transitions because they are not designed for such a task. This leads to significant visual artifacts, such as image blur or shader-generated shadows appearing on top of FMV or Menu.
</p>

<h2>The Solution: Static Depth Detection</h2>
<p>
  This shader introduces <b>depth activity</b> tracking and <b>color-jump</b> detection through a lightweight <b>scan-points</b> system. It functions as a trigger to automatically toggle desired effects off/on when 3D rendering freezes.
</p>

<h2>Requirements & Limitations</h2>
<ul>
  <li><strong>ReShade:</strong> 6.0 or higher.</li>
  <li><strong>Graphics API:</strong>
  <ul>
    <li>DirectX 9.0c, 10, 11 − full support.</li>
    <li>DirectX 12, Vulkan, OpenGL 4.x − <ins>depends on game's depth buffer support</ins>.</li>
  </ul>
  <li><strong>Anti-Aliasing:</strong> Disable MSAA in game settings for depth detection to work.</li>
  <li><strong>Generic Depth:</strong> Depth Addon must be enabled in ReShade's settings.</li>
  <li><strong>Depth Input:</strong> The depth input must have the correct polarity (<code>RESHADE_DEPTH_INPUT_IS_REVERSED</code>) to track depth state changes properly.</li>
</ul>  

<br>
<br>
<p align="center">
    © 2026 MarineSolder • <strong>Discord:</strong> <code>marinesolder</code> • 
    <a href="https://github.com/MarineSolder/Static-Depth-Detect/issues">Report a bug</a>
</p>
