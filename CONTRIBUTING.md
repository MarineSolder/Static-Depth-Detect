# Contributing to Static Depth Detect

Thank you for your interest. Please read this before opening Issues or
Pull Requests.

## Issues are welcome

For bug reports, edge cases, compatibility problems with specific games please 
open an issue. Please include:

- Your PC specs
- ReShade version
- Game name and version
- Settings used
- Description of the issue 
- Screenshots or short gameplay video (if applicable)

## Pull Requests by invitation only

This project does not accept unsolicited Pull Requests.

If you have an idea for an improvement, please open an Issue first to
discuss the approach. If the idea is a good fit, you will be invited
to submit a Pull Request.

Pull Requests opened without prior discussion will be closed without review.

## Why?

This shader has a tightly coupled state machine across multiple passes and
textures. Changes that look isolated often have non-obvious effects on
detection stability. Discussion before code keeps the project consistent.
