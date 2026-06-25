import type { CSSProperties, ReactNode } from "react";

interface Block3DProps {
  /** CSS color expression for cube faces, e.g. `var(--fee-3)` */
  color: string;
  /** Size of the cube face in px. Defaults to 140. */
  size?: number;
  /** Cube depth in px. Defaults to 40. */
  depth?: number;
  /** Tilt about Y axis (deg). Negative shows right face on the right, positive on the left. */
  rotateY?: number;
  /** Tilt about X axis (deg). */
  rotateX?: number;
  /** Optional scale (for receding chain). */
  scale?: number;
  /** "Empty" portion from the top — 0 means fully filled, 100 means fully empty. */
  emptyPct?: number;
  /** Content rendered on the front face. */
  children: ReactNode;
  className?: string;
}

/**
 * A real CSS 3D cube — front / top / right faces with photorealistic shading
 * (multi-stop gradients, specular highlight, inset bevels, ambient occlusion).
 */
export function Block3D({
  color,
  size = 140,
  depth = 40,
  rotateY = -30,
  rotateX = -20,
  scale = 1,
  emptyPct = 0,
  children,
  className,
}: Block3DProps) {
  const halfD = depth / 2;
  const containerStyle: CSSProperties = {
    width: size + depth,
    height: size + depth,
  };
  const cubeStyle: CSSProperties = {
    width: size,
    height: size,
    position: "absolute",
    top: depth / 2,
    left: depth / 2,
    transform: `rotateX(${rotateX}deg) rotateY(${rotateY}deg) scale(${scale})`,
    // pass color into the face CSS
    ["--c" as any]: color,
    ["--empty" as any]: `${emptyPct}%`,
  };

  return (
    <div className={`relative ${className ?? ""}`} style={containerStyle}>
      <div className="cube-3d" style={cubeStyle}>
        {/* Back face omitted (hidden) */}
        {/* Right face */}
        <div
          className="cube-face cube-right"
          style={{
            width: depth,
            transform: `rotateY(90deg) translateZ(${size - halfD}px)`,
            transformOrigin: "left center",
            left: size,
            top: 0,
            height: size,
          }}
        />
        {/* Top face */}
        <div
          className="cube-face cube-top"
          style={{
            height: depth,
            transform: `rotateX(-90deg) translateZ(${halfD}px)`,
            transformOrigin: "center top",
            top: 0,
            left: 0,
            width: size,
          }}
        />
        {/* Front face (with content) */}
        <div
          className="cube-face cube-front"
          style={{
            transform: `translateZ(${halfD}px)`,
            width: size,
            height: size,
          }}
        >
          <div className="cube-front-fill" />
          <div className="relative z-10 size-full flex flex-col items-center justify-center text-white">
            {children}
          </div>
        </div>
        <div className="cube-shadow" />
      </div>
    </div>
  );
}
