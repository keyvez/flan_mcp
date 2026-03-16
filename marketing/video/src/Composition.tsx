import React from "react";
import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";

type Line = {
	start: number;
	text: string;
	color?: string;
	speed?: number;
};

const palette = {
	bg: "#0a0d0b",
	panel: "#101512",
	panel2: "#0d120f",
	line: "#26342b",
	text: "#dce7df",
	muted: "#91a297",
	green: "#8dd694",
	amber: "#e9c46a",
	cyan: "#89dceb",
	orange: "#ff9f43",
	flutterBlue: "#58a6ff",
};

const url = "ws://127.0.0.1:52794/N2Tizytts-E=/ws";

const typeLine = (frame: number, line: Line) => {
	if (frame < line.start) {
		return "";
	}

	const speed = line.speed ?? 1.2;
	const chars = Math.floor((frame - line.start) / speed);
	return line.text.slice(0, Math.max(0, Math.min(line.text.length, chars)));
};

const spinnerFrame = (frame: number) => {
	const symbols = ["|", "/", "-", "\\"];
	return symbols[Math.floor(frame / 6) % symbols.length];
};

const blockStyle: React.CSSProperties = {
	background: `linear-gradient(180deg, ${palette.panel}, ${palette.panel2})`,
	border: `1px solid ${palette.line}`,
	boxShadow: "0 0 0 1px rgba(0,0,0,0.15) inset",
};

const panelTitleStyle: React.CSSProperties = {
	fontSize: 14,
	color: palette.cyan,
	marginBottom: 10,
	letterSpacing: 0.2,
};

const rowStyle = (color?: string): React.CSSProperties => ({
	fontSize: 15,
	whiteSpace: "pre",
	color: color ?? palette.text,
	marginBottom: 7,
});

const ShortcutOverlay: React.FC<{
	visible: boolean;
	keys: string[];
	label: string;
	top?: number;
	right?: number;
	bottom?: number;
	left?: number;
}> = ({ visible, keys, label, top, right, bottom, left }) => {
	if (!visible) {
		return null;
	}

	return (
		<div
			style={{
				position: "absolute",
				top,
				right,
				bottom,
				left,
				zIndex: 4,
				display: "flex",
				flexDirection: "column",
				gap: 6,
			}}
		>
			<div style={{ fontSize: 11, color: palette.muted }}>{label}</div>
			<div style={{ display: "flex", gap: 6 }}>
				{keys.map((key) => (
					<div
						key={key}
						style={{
							minWidth: 28,
							height: 28,
							padding: "0 9px",
							display: "flex",
							alignItems: "center",
							justifyContent: "center",
							border: `1px solid ${palette.amber}`,
							background: "rgba(233,196,106,0.16)",
							color: palette.amber,
							fontSize: 13,
						}}
					>
						{key}
					</div>
				))}
			</div>
		</div>
	);
};

const FlutterTerminal: React.FC<{ frame: number }> = ({ frame }) => {
	const lines: Line[] = [
		{
			start: 12,
			text: "$ cd example && flutter run -d chrome",
			color: palette.cyan,
			speed: 2.35,
		},
		{
			start: 108,
			text: "Launching lib/main.dart on Chrome in debug mode...",
			color: palette.text,
			speed: 0.18,
		},
		{
			start: 132,
			text: "Waiting for connection from debug service on Chrome...",
			color: palette.text,
			speed: 0.18,
		},
		{
			start: 162,
			text: "This app is linked to the debug service:",
			color: palette.muted,
			speed: 0.2,
		},
	];

	const shownUrl = typeLine(frame, {
		start: 188,
		text: url,
		color: palette.amber,
		speed: 0.22,
	});

	const selectProgress = interpolate(frame, [232, 284], [0, 1], {
		extrapolateLeft: "clamp",
		extrapolateRight: "clamp",
	});
	const selectedChars = Math.floor(shownUrl.length * selectProgress);

	return (
		<div style={{ ...blockStyle, padding: 14, height: "100%", position: "relative" }}>
			<div style={panelTitleStyle}>flutter terminal</div>
			{lines.map((line, i) => {
				const shown = typeLine(frame, line);
				if (shown.length === 0) return null;
				return (
					<div key={i} style={rowStyle(line.color)}>
						{shown}
					</div>
				);
			})}

			{shownUrl.length > 0 ? (
				<div style={rowStyle(palette.amber)}>
					<span
						style={{
							background:
								selectedChars > 0 ? "rgba(88,166,255,0.35)" : "transparent",
							color: selectedChars > 0 ? "#f5fbff" : palette.amber,
						}}
					>
						{shownUrl.slice(0, selectedChars)}
					</span>
					<span>{shownUrl.slice(selectedChars)}</span>
				</div>
			) : null}

			<ShortcutOverlay
				visible={frame >= 286 && frame < 314}
				keys={["⌘", "C"]}
				label="user shortcut"
				right={12}
				bottom={12}
			/>
		</div>
	);
};

const AgentPanel: React.FC<{ frame: number }> = ({ frame }) => {
	const agentRowStyle = (color?: string): React.CSSProperties => ({
		...rowStyle(color),
		whiteSpace: "normal",
		overflowWrap: "anywhere",
		wordBreak: "break-word",
		fontSize: 13,
		lineHeight: "17px",
		marginBottom: 4,
	});

	const connectPrefix = typeLine(frame, {
		start: 292,
		text: "> connect ",
		speed: 2.3,
		color: palette.cyan,
	});
	const pastedUrl = frame >= 316 ? url : "";

	const lines: Line[] = [
		{ start: 334, text: "[agent] connected", color: palette.green, speed: 0.28 },
		{
			start: 350,
			text: "[agent] auto> process_queue",
			color: palette.cyan,
			speed: 0.28,
		},
		{
			start: 376,
			text: "[agent] waiting for user message...",
			color: palette.muted,
			speed: 0.3,
		},
		{
			start: 606,
			text: '[user] "color this flan green"',
			color: palette.amber,
			speed: 1.0,
		},
		{
			start: 644,
			text: "[agent] received messages from process_queue",
			color: palette.green,
			speed: 0.28,
		},
		{
			start: 670,
			text: "[agent] I see that the user wants to change the color of the Container widget",
			color: palette.text,
			speed: 0.22,
		},
		{
			start: 704,
			text: "[agent] context under rectangle: Container(color: ...) in Flutter counter app",
			color: palette.muted,
			speed: 0.22,
		},
		{
			start: 736,
			text: "[agent] preparing patch + hot_reload",
			color: palette.cyan,
			speed: 0.25,
		},
	];

	const doneLines: Line[] = [
		{ start: 774, text: "[agent] patch applied", color: palette.green, speed: 0.28 },
		{ start: 786, text: "[agent] hot_reload", color: palette.cyan, speed: 0.28 },
		{
			start: 798,
			text: "[agent] verified with inspect_widget_at",
			color: palette.green,
			speed: 0.25,
		},
	];

	const working = frame >= 756 && frame < 774;
	const done = frame >= 774;

	return (
		<div style={{ ...blockStyle, padding: 14, height: "100%", position: "relative" }}>
			<div style={panelTitleStyle}>atlas-code agent</div>

			{connectPrefix.length > 0 ? (
				<div style={agentRowStyle(palette.cyan)}>
					{connectPrefix}
					<span style={{ color: palette.amber }}>{pastedUrl}</span>
				</div>
			) : null}

				{lines.map((line, i) => {
					const shown = typeLine(frame, line);
					if (shown.length === 0) return null;
					return (
						<div key={i} style={agentRowStyle(line.color)}>
							{shown}
						</div>
					);
				})}

				{working ? (
					<div style={{ ...agentRowStyle(), marginTop: 9 }}>
						[agent] applying change {spinnerFrame(frame)}
					</div>
				) : null}

			{done ? (
				<div style={{ marginTop: 9 }}>
						{doneLines.map((line, i) => {
							const shown = typeLine(frame, line);
							if (shown.length === 0) return null;
							return (
								<div key={i} style={agentRowStyle(line.color)}>
									{shown}
								</div>
							);
					})}
				</div>
			) : null}

			<ShortcutOverlay
				visible={frame >= 316 && frame < 344}
				keys={["⌘", "V"]}
				label="user shortcut"
				right={12}
				bottom={12}
			/>
		</div>
	);
};

const RightAppPanel: React.FC<{ frame: number }> = ({ frame }) => {
	const applied = frame >= 774;

	const annotationProgress = interpolate(frame, [430, 512], [0, 1], {
		extrapolateLeft: "clamp",
		extrapolateRight: "clamp",
	});
	const annotationVisible = frame >= 430 && frame < 692;
	const annotationInputVisible = frame >= 512 && frame < 692;
	const annotationText = typeLine(frame, {
		start: 520,
		text: "color this flan green",
		speed: 1.6,
	});
	const annotationSubmitVisible = frame >= 560 && frame < 600;

	const boxWidth = 360;
	const boxHeight = 172;
	const boxX = 80;
	const boxY = 106;
	const dragBoxWidth = interpolate(annotationProgress, [0, 1], [8, boxWidth]);
	const dragBoxHeight = interpolate(annotationProgress, [0, 1], [8, boxHeight]);

	const fabColor = applied ? palette.green : palette.flutterBlue;
	const cardBorder = applied ? palette.green : palette.line;
	const cardBackground = applied
		? "rgba(63,178,95,0.72)"
		: "rgba(255,255,255,0.02)";
	const cardTextColor = applied ? "#071409" : palette.text;
	const cardMutedColor = applied ? "#0d2211" : palette.muted;

	return (
		<div
			style={{
				...blockStyle,
				height: "100%",
				padding: 14,
				position: "relative",
			}}
		>
			<div style={panelTitleStyle}>flan demo app</div>
			{applied ? (
				<div
					style={{
						position: "absolute",
						right: 18,
						top: 52,
						border: `1px solid ${palette.green}`,
						background: "rgba(63,178,95,0.2)",
						color: palette.text,
						padding: "8px 10px",
						fontSize: 12,
						zIndex: 2,
					}}
				>
					flan theme applied after hot reload
				</div>
			) : null}

			<div
				style={{
					border: `1px solid ${palette.line}`,
					background: "#0b100d",
					height: 520,
					padding: 0,
					position: "relative",
					overflow: "hidden",
				}}
			>
				<div
					style={{
						height: 44,
						display: "flex",
						alignItems: "center",
						paddingLeft: 16,
						background: "rgba(255,255,255,0.03)",
						borderBottom: `1px solid ${palette.line}`,
						color: palette.text,
						fontSize: 14,
					}}
				>
					Flutter Demo Home Page
				</div>

				<div
					style={{
						position: "absolute",
						left: 94,
						top: 122,
						width: 330,
						border: `1px solid ${cardBorder}`,
						background: cardBackground,
						padding: 18,
					}}
				>
					<div style={{ color: cardMutedColor, fontSize: 14, marginBottom: 10 }}>
						You have pushed the button this many times:
					</div>
					<div
						style={{
							color: cardTextColor,
							fontSize: 52,
							lineHeight: "52px",
						}}
					>
						0
					</div>
				</div>

				<div
					style={{
						position: "absolute",
						right: 44,
						bottom: 42,
						width: 56,
						height: 56,
						borderRadius: 28,
						background: fabColor,
						color: "#081108",
						fontSize: 34,
						display: "flex",
						alignItems: "center",
						justifyContent: "center",
						fontWeight: 700,
					}}
				>
					+
				</div>

				{annotationVisible ? (
					<svg
						style={{
							position: "absolute",
							left: 0,
							top: 0,
							width: "100%",
							height: "100%",
							pointerEvents: "none",
						}}
					>
						<rect
							x={boxX}
							y={boxY}
							width={dragBoxWidth}
							height={dragBoxHeight}
							fill="rgba(255,159,67,0.09)"
							stroke={palette.orange}
							strokeWidth={3}
						/>
					</svg>
				) : null}

				{annotationInputVisible ? (
					<div
						style={{
							position: "absolute",
							left: boxX,
							top: boxY + boxHeight + 10,
							width: 250,
							border: `1px solid ${palette.orange}`,
							background: "rgba(255,159,67,0.14)",
							color: palette.amber,
							padding: "7px 9px",
							fontSize: 13,
						}}
					>
						{annotationText}
					</div>
				) : null}

				<ShortcutOverlay
					visible={annotationSubmitVisible}
					keys={["Enter"]}
					label="user submit"
					left={boxX + 186}
					top={boxY + boxHeight + 44}
				/>
			</div>
		</div>
	);
};

export const FlanAgentFlowComposition: React.FC = () => {
	const frame = useCurrentFrame();

	const glowOpacity = interpolate(frame, [0, 120], [0.05, 0.14], {
		extrapolateLeft: "clamp",
		extrapolateRight: "clamp",
	});

	return (
		<AbsoluteFill
			style={{
				fontFamily:
					'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
				backgroundColor: palette.bg,
				color: palette.text,
			}}
		>
			<div
				style={{
					position: "absolute",
					inset: 0,
					background:
						"repeating-linear-gradient(180deg, rgba(255,255,255,0.03) 0, rgba(255,255,255,0.03) 1px, transparent 1px, transparent 3px)",
					opacity: 0.32,
				}}
			/>

			<div
				style={{
					position: "absolute",
					right: 36,
					top: 26,
					width: 340,
					height: 240,
					background: `radial-gradient(circle, rgba(141,214,148,${glowOpacity}) 0%, rgba(141,214,148,0) 65%)`,
				}}
			/>

			<div
				style={{
					padding: 22,
					display: "grid",
					gridTemplateColumns: "1.02fr 0.98fr",
					gap: 14,
					height: "100%",
				}}
			>
				<div style={{ display: "grid", gridTemplateRows: "0.52fr 1.48fr", gap: 14 }}>
					<FlutterTerminal frame={frame} />
					<AgentPanel frame={frame} />
				</div>
				<RightAppPanel frame={frame} />
			</div>
		</AbsoluteFill>
	);
};
