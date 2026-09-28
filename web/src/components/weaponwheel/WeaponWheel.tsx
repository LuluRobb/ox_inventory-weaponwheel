import React, { useEffect, useState } from 'react';
import useNuiEvent from '../../hooks/useNuiEvent';
import { useAppSelector } from '../../store';
import { selectLeftInventory } from '../../store/inventory';
import { Items } from '../../store/items';
import { Locale } from '../../store/locale';
import { getItemUrl, isSlotWithItem } from '../../helpers';
import { SlotWithItem } from '../../typings';
import './weaponwheel.scss';

// Index 0-4 = inventory slot 1-5, index 5 = fist. Angle 0 = top, clockwise.
// Must match SLOT_ANGLE in modules/weaponwheel/client.lua
const ANGLES = [240, 300, 0, 60, 120, 180];
const FIST = 5;

const R_IN = 132;
const R_OUT = 276;
const RIM_IN = 282;
const RIM_OUT = 288;
const GAP = 6;
const LABEL_R = (R_IN + R_OUT) / 2 + 14;
const SLOTNO_R = R_IN + 18;

const rad = (deg: number) => (deg * Math.PI) / 180;
const pt = (r: number, a: number) => [r * Math.sin(a), -r * Math.cos(a)];

// Annular sector with a constant pixel gap between neighbours
const sector = (centerDeg: number, spanDeg: number, r0: number, r1: number, gap: number) => {
  const a0 = rad(centerDeg - spanDeg / 2);
  const a1 = rad(centerDeg + spanDeg / 2);
  const g0 = gap / 2 / r0;
  const g1 = gap / 2 / r1;
  const [x1, y1] = pt(r1, a0 + g1);
  const [x2, y2] = pt(r1, a1 - g1);
  const [x3, y3] = pt(r0, a1 - g0);
  const [x4, y4] = pt(r0, a0 + g0);
  return `M${x1} ${y1}A${r1} ${r1} 0 0 1 ${x2} ${y2}L${x3} ${y3}A${r0} ${r0} 0 0 0 ${x4} ${y4}Z`;
};

const pos = (r: number, deg: number): React.CSSProperties => {
  const [x, y] = pt(r, rad(deg));
  return { left: `${(x + 300) / 6}%`, top: `${(y + 300) / 6}%` };
};

// No segment, used for "nothing selected" and weapons outside slots 1-5
const NONE = -1;

// Lua uses slot numbers with 0 = fist, the wheel uses segment indices
const slotToIndex = (slot?: number | null) => (slot === 0 ? FIST : slot && slot >= 1 && slot <= 5 ? slot - 1 : NONE);

const FistIcon: React.FC = () => (
  <svg
    viewBox="0 0 64 64"
    fill="none"
    stroke="currentColor"
    strokeWidth="3"
    strokeLinejoin="round"
    strokeLinecap="round"
  >
    <path d="M16 31V22a4 4 0 0 1 8 0v6" />
    <path d="M24 26v-8a4 4 0 0 1 8 0v8" />
    <path d="M32 26v-7a4 4 0 0 1 8 0v8" />
    <path d="M40 27v-4a4 4 0 0 1 8 0v15c0 9-6 16-15 16h-3c-8 0-14-6-14-14v-9" />
    <path d="M16 36h11a4 4 0 0 1 0 8h-5" />
  </svg>
);

const ItemIcon: React.FC<{ item: SlotWithItem }> = ({ item }) => {
  const [failed, setFailed] = useState(false);
  const url = getItemUrl(item);

  useEffect(() => setFailed(false), [url]);

  if (failed || !url) return <span className="ww-fallback">{item.name.replace('WEAPON_', '').slice(0, 10)}</span>;

  return <img src={url} alt="" onError={() => setFailed(true)} />;
};

interface WheelItem {
  item: SlotWithItem;
  label: string;
  ammo?: number;
  capacity?: number;
}

// Slot holds an item that is not a weapon
const OCCUPIED = 'occupied';

type WheelEntry = WheelItem | typeof OCCUPIED | null;

interface SlotState {
  blocked?: boolean[];
  capacity?: number[];
}

interface OpenData extends SlotState {
  equipped?: number;
  hovered?: number;
  ammo?: number;
}

// Rendering only, input handling and selection run in modules/weaponwheel/client.lua
const WeaponWheel: React.FC = () => {
  const [open, setOpen] = useState(false);
  const [hovered, setHovered] = useState(FIST);
  // Slot number of the current weapon, 0 = unarmed
  const [equipped, setEquipped] = useState(0);
  const [liveAmmo, setLiveAmmo] = useState<number | null>(null);
  // Weapons that can not be used on the current vehicle seat, shown greyed out and skipped
  const [blockedSlots, setBlockedSlots] = useState<boolean[]>([]);
  const [capacities, setCapacities] = useState<number[]>([]);
  const inventoryItems = useAppSelector(selectLeftInventory).items;

  // Lua arrays arrive as json arrays, index 0 = slot 1
  const setSlotState = (data?: SlotState) => {
    setBlockedSlots(Array.isArray(data?.blocked) ? data.blocked : []);
    // Max clip size per slot incl. attached clip components, read from the game in Lua
    setCapacities(Array.isArray(data?.capacity) ? data.capacity : []);
  };

  useNuiEvent<OpenData>('openWeaponWheel', (data) => {
    setEquipped(data?.equipped ?? 0);
    setLiveAmmo(typeof data?.ammo === 'number' ? data.ammo : null);
    setSlotState(data);
    setHovered(slotToIndex(data?.hovered));
    setOpen(true);
  });

  useNuiEvent<number>('weaponWheelHover', (slot) => setHovered(slotToIndex(slot)));

  // Sent when the inventory or the vehicle seat changes while the wheel is open
  useNuiEvent<SlotState>('weaponWheelUpdate', setSlotState);

  useNuiEvent('closeWeaponWheel', () => setOpen(false));

  const getEntry = (index: number): WheelEntry => {
    const slot = inventoryItems.find((item) => item.slot === index + 1);
    if (!slot || !isSlotWithItem(slot)) return null;

    // Read from the live inventory, same check as isWeaponSlot in Lua
    const data = Items[slot.name];
    if (!data?.weapon) return OCCUPIED;

    const label = slot.metadata?.label || data?.label || slot.name;
    const ammoName = data?.ammoName;

    if (!ammoName) return { item: slot, label };

    const ammo = equipped === slot.slot && liveAmmo !== null ? liveAmmo : (slot.metadata?.ammo ?? 0);
    return { item: slot, label, ammo, capacity: capacities[index] || undefined };
  };

  const entries: WheelEntry[] = ANGLES.map((_, i) => (i === FIST ? null : getEntry(i)));

  const fistLabel = Locale.ui_weaponwheel_fist || 'Fist';
  const emptyLabel = Locale.ui_weaponwheel_empty || 'Empty';
  const occupiedLabel = Locale.ui_weaponwheel_occupied || 'Occupied';

  const isBlocked = (index: number) => index !== FIST && !!blockedSlots[index];

  const isGreyed = (index: number) =>
    index !== FIST && (!entries[index] || entries[index] === OCCUPIED || isBlocked(index));

  const renderAmmo = (entry: WheelItem) =>
    entry.ammo !== undefined ? (
      <div className="ww-ammo">
        {entry.ammo}
        {entry.capacity !== undefined && <span> / {entry.capacity}</span>}
      </div>
    ) : (
      entry.item.count > 1 && <div className="ww-ammo">{entry.item.count}x</div>
    );

  const renderLabelContent = (index: number) => {
    if (index === FIST) {
      return (
        <>
          <div className="ww-icon">
            <FistIcon />
          </div>
          <div className="ww-ammo">{fistLabel}</div>
        </>
      );
    }

    const entry = entries[index];

    if (!entry || entry === OCCUPIED) {
      return (
        <>
          <div className="ww-icon">
            <div className="ww-empty-icon" />
          </div>
          <div className="ww-empty-text">{entry ? occupiedLabel : emptyLabel}</div>
        </>
      );
    }

    return (
      <>
        <div className="ww-icon">
          <ItemIcon item={entry.item} />
        </div>
        {renderAmmo(entry)}
      </>
    );
  };

  const renderInfo = () => {
    if (hovered === NONE) return null;
    if (hovered === FIST) return <div className="ww-name">{fistLabel}</div>;

    const entry = entries[hovered];
    if (!entry || entry === OCCUPIED) return <div className="ww-name muted">{entry ? occupiedLabel : emptyLabel}</div>;

    const components: string[] = Array.isArray(entry.item.metadata?.components) ? entry.item.metadata.components : [];

    return (
      <>
        <div className="ww-name">{entry.label}</div>
        {renderAmmo(entry)}
        {components.length > 0 && (
          <div className="ww-comps" key={entry.item.slot}>
            {components.map((name, i) => (
              <div className="ww-comp-tile" key={`${name}-${i}`}>
                <img src={getItemUrl(name)} alt="" />
              </div>
            ))}
          </div>
        )}
      </>
    );
  };

  const equippedIndex = slotToIndex(equipped);

  const stateClass = (index: number) =>
    `${index === hovered ? ' hover' : ''}${index === equippedIndex ? ' equipped' : ''}${isBlocked(index) ? ' blocked' : ''}`;

  return (
    <div className={`weapon-wheel${open ? ' open' : ''}`}>
      <div className="ww-dim" />
      <div className="ww-stage">
        <div className="ww-wheel">
          <svg className="ww-svg" viewBox="-300 -300 600 600" aria-hidden="true">
            <circle className="ww-center-disc" r={R_IN - 10} />
            <circle className="ww-center-ring" r={R_IN - 16} />
            {ANGLES.map((deg, i) => (
              <g key={i} className={`ww-seg${isGreyed(i) ? ' empty' : ''}${stateClass(i)}`}>
                <path className="ww-body" d={sector(deg, 60, R_IN, R_OUT, GAP)} />
                <path className="ww-rim" d={sector(deg, 60, RIM_IN, RIM_OUT, GAP)} />
              </g>
            ))}
          </svg>
          <div>
            {ANGLES.map((deg, i) => (
              <React.Fragment key={i}>
                <div className={`ww-label${stateClass(i)}`} style={pos(LABEL_R, deg)}>
                  {renderLabelContent(i)}
                </div>
                {/* Slot number sits on the inner edge, centered on the segment */}
                {i !== FIST && (
                  <div className={`ww-slotno${stateClass(i)}`} style={pos(SLOTNO_R, deg)}>
                    {i + 1}
                  </div>
                )}
              </React.Fragment>
            ))}
          </div>
          <div className="ww-info">{renderInfo()}</div>
        </div>
      </div>
    </div>
  );
};

export default WeaponWheel;
