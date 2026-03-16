import { Composition } from "remotion";
import { FlanAgentFlowComposition } from "./Composition";
import { FLAN_AGENT_FLOW_META } from "./composition-meta";

export const RemotionRoot: React.FC = () => {
	return (
		<>
				<Composition
					id={FLAN_AGENT_FLOW_META.id}
					component={FlanAgentFlowComposition}
					durationInFrames={FLAN_AGENT_FLOW_META.durationInFrames}
					fps={FLAN_AGENT_FLOW_META.fps}
					width={FLAN_AGENT_FLOW_META.width}
					height={FLAN_AGENT_FLOW_META.height}
				/>
		</>
	);
};
