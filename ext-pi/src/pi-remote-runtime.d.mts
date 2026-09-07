export interface RemotePiSessionSummary {
  serverId: string;
  sessionId: string;
  createdAt: number;
}

export interface RemotePiConnection {
  listSessions(): readonly RemotePiSessionSummary[];
  dispose(): Promise<void>;
}

export function openRemotePi(socketPath: string): Promise<RemotePiConnection>;
