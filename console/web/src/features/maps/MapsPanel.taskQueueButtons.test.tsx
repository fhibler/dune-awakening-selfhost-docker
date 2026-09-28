import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { mapsApi } from "../../api/maps";
import { MapsPanel } from "./MapsPanel";
import { invalidateInstanceNames } from "./instanceNames";

// Save and Restart share one per-target queue slot, so both are disabled while
// either runs. Only the button that started the task may show its progress
// label: restarting a Sietch used to relabel that Sietch's "Save Sietch
// Settings" button too, which read as a save the operator never asked for.

vi.mock("../../api/maps", () => ({
  mapsApi: new Proxy({} as Record<string, unknown>, {
    get: (target, prop: string) => {
      if (!target[prop]) {
        target[prop] = vi.fn().mockResolvedValue({
          stdout: "", exitCode: 0,
          rows: [], placements: [], tradeCenters: [], partitions: [], fields: [],
          partition: [], game: [], engine: [], global: [],
          capabilities: {}, values: {}, sampledAt: ""
        });
      }
      return target[prop];
    }
  })
}));
vi.mock("../../api/setup", () => ({ setupApi: new Proxy({} as Record<string, unknown>, {
  get: (target, prop: string) => {
    if (!target[prop]) target[prop] = vi.fn().mockResolvedValue({});
    return target[prop];
  }
}) }));
// runGatedRestart reads the queue status and the pending-write queues before it
// shows the dialog; none of them may reach the network from a component test.
vi.mock("../../api/server", () => ({
  serverApi: {
    restartQueue: vi.fn().mockResolvedValue(null),
    restart: vi.fn().mockResolvedValue({}),
    restartHistory: vi.fn().mockResolvedValue({ rows: [], lastBattlegroupRestart: null })
  }
}));
vi.mock("../../api/bases", () => ({ basesApi: new Proxy({} as Record<string, unknown>, {
  get: (target, prop: string) => {
    if (!target[prop]) target[prop] = vi.fn().mockResolvedValue(null);
    return target[prop];
  }
}) }));
vi.mock("../../api/vehicles", () => ({ vehiclesApi: new Proxy({} as Record<string, unknown>, {
  get: (target, prop: string) => {
    if (!target[prop]) target[prop] = vi.fn().mockResolvedValue(null);
    return target[prop];
  }
}) }));
vi.mock("../../lib/usePendingRefills", () => ({
  usePendingRefills: () => ({ pending: null, refresh: () => {} }),
  usePendingQueues: () => ({
    fuel: { pending: null, refresh: () => {} },
    water: { pending: null, refresh: () => {} },
    deletes: { pending: null, refresh: () => {} },
    vehicleDeletes: { pending: null, refresh: () => {} },
    permissions: { pending: null, refresh: () => {} }
  }),
  pendingRefillCountForMap: () => 0,
  pendingRefillCountForPartition: () => 0,
  vehicleDeleteCountForMap: () => 0,
  vehicleDeleteCountForPartition: () => 0,
  childAccessPieceCountForMap: () => 0,
  childAccessPieceCountForPartition: () => 0
}));

const TABLE = [
  "DIMENSION  DISPLAY NAME                     PASSWORD",
  "0          Hagga Basin                      (unset)",
  "1          Sietch Abbir                     (set)",
  "2          The Kulon Show                   (unset)"
].join("\n");
const IDS = "1\n31\n32\n";

const MAPS_JSON = JSON.stringify({
  maps: [{ map: "Survival_1", status: "Ready", mode: "Core Map", memory: "12 GB", partitionId: "" }]
});

function stubMapsApi() {
  const api = mapsApi as unknown as Record<string, ReturnType<typeof vi.fn>>;
  api.status.mockResolvedValue({
    maps: { stdout: MAPS_JSON },
    services: { stdout: "" },
    readiness: { stdout: "" }
  });
  api.sietchDimensions.mockImplementation((_map?: string, ids?: boolean) =>
    Promise.resolve({ stdout: ids ? IDS : TABLE, exitCode: 0 }));
  api.updateSietches.mockResolvedValue({ task: { id: "save-1", status: "succeeded" } });
  api.restartSietch.mockResolvedValue({ task: { id: "restart-1", status: "running" } });
  return api;
}

function renderMapsPanel() {
  const props = {
    onError: vi.fn(),
    confirmAction: vi.fn().mockResolvedValue(true),
    confirmSettingsRestart: vi.fn().mockResolvedValue("immediate"),
    waitForTaskWithUpdates: vi.fn().mockImplementation((task: { id: string }) =>
      Promise.resolve({ ...task, status: "succeeded" })),
    taskTechnicalDetails: vi.fn().mockReturnValue(""),
    restartGate: vi.fn().mockResolvedValue("immediate")
  };
  render(<MapsPanel {...props} />);
  return props;
}

function sietchRow(partitionId: string) {
  const meta = [...document.querySelectorAll(".sietch-child-meta")]
    .find((node) => node.textContent?.startsWith(`Partition ${partitionId} /`));
  return meta?.closest("tr") as HTMLElement;
}

async function openSietch(partitionId: string) {
  const row = await waitFor(() => {
    const found = sietchRow(partitionId);
    expect(found).toBeTruthy();
    return found;
  });
  fireEvent.click(within(row).getByRole("button", { name: "Edit" }));
}

function nameInput() {
  const label = [...document.querySelectorAll(".inline-edit-panel label")]
    .find((node) => node.textContent?.startsWith("Name"));
  return label?.querySelector("input") as HTMLInputElement;
}

// The inline panel's buttons in DOM order: Save is the first action, Restart
// the one titled for this Sietch. Matched by title/position rather than by
// label, because the label is exactly what is under test.
function saveButton() {
  return [...document.querySelectorAll(".inline-edit-panel .action-line button")]
    .find((node) => !node.getAttribute("title")) as HTMLButtonElement;
}
function restartButton() {
  return document.querySelector(".inline-edit-panel .action-line button[title='Restart only this Sietch']") as HTMLButtonElement;
}

beforeEach(() => {
  vi.clearAllMocks();
  invalidateInstanceNames();
});

describe("MapsPanel per-target task buttons", () => {
  it("only relabels the Restart button while that Sietch restarts", async () => {
    const api = stubMapsApi();
    const props = renderMapsPanel();
    let finishTask!: () => void;
    const taskCompletion = new Promise<void>((resolve) => { finishTask = resolve; });
    props.waitForTaskWithUpdates.mockImplementation(async (task: { id: string }) => {
      await taskCompletion;
      return { ...task, status: "succeeded" };
    });

    await openSietch("31");
    // A pending edit, so the Save button is enabled by dirtiness alone and any
    // change to it comes from the restart rather than from the dirty check.
    fireEvent.change(nameInput(), { target: { value: "Renamed" } });
    expect(saveButton().textContent).toBe("Save Sietch Settings");
    expect(saveButton().disabled).toBe(false);

    fireEvent.click(restartButton());
    await waitFor(() => expect(api.restartSietch).toHaveBeenCalled());
    await waitFor(() => expect(restartButton().textContent).toBe("Restarting..."));

    // Still blocked -- one write at a time per partition -- but it must not
    // claim a save is running.
    expect(saveButton().textContent).toBe("Save Sietch Settings");
    expect(saveButton().disabled).toBe(true);

    finishTask();
    await waitFor(() => expect(restartButton().textContent).toBe("Restart"));
    await waitFor(() => expect(saveButton().disabled).toBe(false));
  });

  it("only relabels the Save button while that Sietch saves", async () => {
    const api = stubMapsApi();
    const props = renderMapsPanel();
    let finishTask!: () => void;
    const taskCompletion = new Promise<void>((resolve) => { finishTask = resolve; });
    props.waitForTaskWithUpdates.mockImplementation(async (task: { id: string }) => {
      await taskCompletion;
      return { ...task, status: "succeeded" };
    });

    await openSietch("31");
    fireEvent.change(nameInput(), { target: { value: "Renamed" } });
    fireEvent.click(screen.getByRole("button", { name: "Save Sietch Settings" }));
    await waitFor(() => expect(api.updateSietches).toHaveBeenCalled());
    await waitFor(() => expect(saveButton().textContent).toBe("Saving..."));

    expect(restartButton().textContent).toBe("Restart");
    expect(restartButton().disabled).toBe(true);

    finishTask();
    await waitFor(() => expect(saveButton().textContent).toBe("Save Sietch Settings"));
  });

  it("leaves the other Sietch's buttons alone while one restarts", async () => {
    const api = stubMapsApi();
    const props = renderMapsPanel();
    let finishTask!: () => void;
    const taskCompletion = new Promise<void>((resolve) => { finishTask = resolve; });
    props.waitForTaskWithUpdates.mockImplementation(async (task: { id: string }) => {
      await taskCompletion;
      return { ...task, status: "succeeded" };
    });

    await openSietch("31");
    fireEvent.click(restartButton());
    await waitFor(() => expect(api.restartSietch).toHaveBeenCalled());
    await waitFor(() => expect(restartButton().textContent).toBe("Restarting..."));

    // Queue state is keyed by partition, so a different Sietch is untouched.
    await openSietch("32");
    expect(restartButton().textContent).toBe("Restart");
    expect(restartButton().disabled).toBe(false);
    finishTask();
  });
});
