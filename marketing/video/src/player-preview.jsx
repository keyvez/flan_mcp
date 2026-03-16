import React from "react";
import {Player} from "@remotion/player";
import {FlanAgentFlowComposition} from "./Composition";
import {FLAN_AGENT_FLOW_META} from "./composition-meta";

const formatTime = (frame, fps) => {
	const totalSeconds = Math.max(0, Math.floor(frame / fps));
	const minutes = Math.floor(totalSeconds / 60);
	const seconds = totalSeconds % 60;
	return `${minutes}:${String(seconds).padStart(2, "0")}`;
};

export const PlayerPreview = () => {
	const playerRef = React.useRef(null);
	const [currentFrame, setCurrentFrame] = React.useState(0);
	const [isPlaying, setIsPlaying] = React.useState(true);
	const [isMuted, setIsMuted] = React.useState(false);

	React.useEffect(() => {
		const player = playerRef.current;
		if (!player) {
			return;
		}

		setCurrentFrame(player.getCurrentFrame());
		setIsPlaying(player.isPlaying());
		setIsMuted(player.isMuted());

		const onFrameUpdate = (event) => {
			setCurrentFrame(event.detail.frame);
		};
		const onPlay = () => {
			setIsPlaying(true);
		};
		const onPause = () => {
			setIsPlaying(false);
		};
		const onEnded = () => {
			setIsPlaying(false);
		};
		const onMuteChange = (event) => {
			setIsMuted(event.detail.isMuted);
		};

		player.addEventListener("frameupdate", onFrameUpdate);
		player.addEventListener("play", onPlay);
		player.addEventListener("pause", onPause);
		player.addEventListener("ended", onEnded);
		player.addEventListener("mutechange", onMuteChange);

		return () => {
			player.removeEventListener("frameupdate", onFrameUpdate);
			player.removeEventListener("play", onPlay);
			player.removeEventListener("pause", onPause);
			player.removeEventListener("ended", onEnded);
			player.removeEventListener("mutechange", onMuteChange);
		};
	}, []);

	const togglePlay = () => {
		const player = playerRef.current;
		if (!player) {
			return;
		}

		if (player.isPlaying()) {
			player.pause();
		} else {
			player.play();
		}
	};

	const toggleMute = () => {
		const player = playerRef.current;
		if (!player) {
			return;
		}

		if (player.isMuted()) {
			player.unmute();
		} else {
			player.mute();
		}
	};

	const seek = (event) => {
		const player = playerRef.current;
		if (!player) {
			return;
		}

		player.seekTo(Number(event.target.value));
	};

	const totalLabel = formatTime(
		FLAN_AGENT_FLOW_META.durationInFrames - 1,
		FLAN_AGENT_FLOW_META.fps,
	);

	return (
		<div style={{width: "100%"}}>
			<Player
				ref={playerRef}
				component={FlanAgentFlowComposition}
				durationInFrames={FLAN_AGENT_FLOW_META.durationInFrames}
				fps={FLAN_AGENT_FLOW_META.fps}
				compositionWidth={FLAN_AGENT_FLOW_META.width}
				compositionHeight={FLAN_AGENT_FLOW_META.height}
				style={{width: "100%"}}
				controls={false}
				moveToBeginningWhenEnded={false}
				autoPlay
			/>
			<div
				style={{
					height: 54,
					display: "grid",
					gridTemplateColumns: "64px 64px auto 1fr",
					alignItems: "center",
					background: "#1a1f1d",
					color: "#f2f4f3",
					fontSize: 14,
				}}
			>
				<button
					type="button"
					onClick={togglePlay}
					aria-label={isPlaying ? "Pause video" : "Play video"}
					style={{
						height: "100%",
						border: 0,
						background: "transparent",
						color: "inherit",
						fontSize: 13,
						cursor: "pointer",
					}}
				>
					{isPlaying ? "Pause" : "Play"}
				</button>
				<button
					type="button"
					onClick={toggleMute}
					aria-label={isMuted ? "Unmute video" : "Mute video"}
					style={{
						height: "100%",
						border: 0,
						background: "transparent",
						color: "inherit",
						fontSize: 13,
						cursor: "pointer",
					}}
				>
					{isMuted ? "Unmute" : "Mute"}
				</button>
				<div style={{padding: "0 12px", fontVariantNumeric: "tabular-nums"}}>
					{formatTime(currentFrame, FLAN_AGENT_FLOW_META.fps)} / {totalLabel}
				</div>
				<div style={{padding: "0 12px"}}>
					<input
						type="range"
						min={0}
						max={FLAN_AGENT_FLOW_META.durationInFrames - 1}
						step={1}
						value={currentFrame}
						onChange={seek}
						aria-label="Seek video"
						style={{width: "100%"}}
					/>
				</div>
			</div>
		</div>
	);
};
