import { api, apiDownload } from "./client";

// The game's own "pick up base" backups (dune.base_backups). See
// docs/console/base-backups.md.

export type BaseBackupRow = {
  id: number;
  ownerControllerId: number | null;
  ownerPawnId: number | null;
  ownerName: string;
  name: string;
  rawName: string;
  map: string;
  totemType: string;
  pieces: number;
  placeables: number;
  items: number;
};

export type BaseBackupList = {
  supported: boolean;
  capabilities?: Record<string, unknown>;
  rows: BaseBackupRow[];
  missing?: string[];
  // Maps a backup may be moved to (where bases are built on this server).
  maps?: string[];
};

export type BaseBackupVersion = {
  build: string;
  steamBuildId?: string | null;
  patchesChecksum: string;
  appliedPatchesCount: number;
};

export type BaseBackupImportResult = {
  ok: true;
  backupId: number;
  name: string;
  playerPawnId: number;
  playerControllerId: number;
  online: boolean;
  counts: { actors: number; pieces: number; placeables: number; items: number };
  version: { mismatch: boolean; file: BaseBackupVersion; server: BaseBackupVersion };
  warnings: string[];
  warning?: string;
};

// Body of a failed export/import (ApiError.body): code "timeout" carries the
// step that ran out of time; "version_mismatch" carries both versions.
export type BaseBackupFailureBody = {
  ok?: false;
  code?: string;
  error?: string;
  operation?: "export" | "import";
  step?: string;
  timeoutKind?: string;
  elapsedMs?: number;
  limitMs?: number;
  file?: BaseBackupVersion;
  server?: BaseBackupVersion;
};

export type BaseBackupUpdateResult = {
  ok: true;
  backupId: number;
  owner: { from: number; fromName: string; to: number } | null;
  name: { from: string; to: string } | null;
  map: { from: string; to: string; actors: number } | null;
  warnings: string[];
  warning?: string;
};

export type BaseBackupDeleteResult = {
  ok: true;
  backupId: number;
  name: string;
  ownerName: string;
  map: string;
  counts: { pieces: number; placeables: number; items: number };
  backupCreated: boolean;
};

export const baseBackupsApi = {
  list: (playerId = "") =>
    api<BaseBackupList>(`/api/base-backups${playerId ? `?playerId=${encodeURIComponent(playerId)}` : ""}`),
  download: (backupId: number) =>
    apiDownload(`/api/base-backups/${encodeURIComponent(String(backupId))}/export`),
  // A live base (a Bases row id) as a base backup file. Read-only on the server.
  downloadLiveBase: (baseId: string) =>
    apiDownload(`/api/bases/${encodeURIComponent(baseId)}/export-backup`),
  importFile: (file: File, playerPawnId: string, allowVersionMismatch = false) => {
    const form = new FormData();
    form.append("file", file);
    form.append("player_id", playerPawnId);
    if (allowVersionMismatch) form.append("allow_version_mismatch", "1");
    return api<BaseBackupImportResult>("/api/base-backups/import", { method: "POST", body: form });
  },
  // Reassign (player pawn id), rename and/or move to another map. The current
  // owner must be offline.
  update: (backupId: number, change: { ownerPlayerId?: string; name?: string; map?: string }) =>
    api<BaseBackupUpdateResult>(`/api/base-backups/${encodeURIComponent(String(backupId))}`, {
      method: "PUT",
      body: JSON.stringify(change)
    }),
  // Permanent. The server takes a full database backup first and refuses while
  // the owner is online; the phrase is the server-side confirmation gate.
  remove: (backupId: number) =>
    api<BaseBackupDeleteResult>(`/api/base-backups/${encodeURIComponent(String(backupId))}`, {
      method: "DELETE",
      body: JSON.stringify({ confirmation: "DELETE BACKUP" })
    })
};
