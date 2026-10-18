// Shared data shapes. Grow this as pages are migrated.

export interface Tournament {
  name: string;
  game?: string;
  date?: string;
  time?: string;
  start?: string;
  prize?: string;
  entry?: string;
  platform?: string;
  slots?: number;
  format?: string;
  status?: string;
  winner?: string | null;
  platform_mode?: 'mobile' | 'emulator' | 'mixed';
}

export interface Bo3Team {
  team: string;
  logo?: string;
  r?: { kills: number; pts: number }[];
}
export interface Bo3 {
  tournament?: string;
  title?: string;
  published?: boolean;
  teams?: Bo3Team[];
}

export interface TournamentsDoc {
  tournaments: Tournament[];
  bo3?: Bo3;
  _published_at?: string;
}

export interface Standing {
  rank: number;
  team: string;
  totalPts: number;
  kills: number;
}
