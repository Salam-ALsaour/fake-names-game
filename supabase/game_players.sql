-- جدول اللاعبين المشترك: أي إضافة أو حذف يظهر عند كل الأجهزة (Realtime)
-- تم تطبيقه على مشروع Supabase "Seraj"
create table public.game_players (
  id bigint generated always as identity primary key,
  title text not null check (char_length(title) between 1 and 100),
  player_name text not null check (char_length(player_name) between 1 and 100),
  color text not null check (color in ('blue', 'red', 'green')),
  created_at timestamptz not null default now()
);

alter table public.game_players enable row level security;

create policy "game_players_select" on public.game_players
  for select to anon, authenticated using (true);
create policy "game_players_insert" on public.game_players
  for insert to anon, authenticated with check (true);
create policy "game_players_delete" on public.game_players
  for delete to anon, authenticated using (true);

alter publication supabase_realtime add table public.game_players;
