-- 10) 모두의 좋아요·싫어요 -------------------------------------------------
-- Supabase → SQL Editor 에 이 파일 내용을 그대로 붙여넣고 Run 하세요. (여러 번 실행해도 괜찮아요)
create table if not exists public.votes (
  user_id    uuid not null references auth.users(id) on delete cascade,
  game_id    text not null check (char_length(game_id) <= 40),
  v          smallint not null check (v in (1, -1)),
  updated_at timestamptz not null default now(),
  primary key (user_id, game_id)
);
alter table public.votes enable row level security;
-- 표 자체는 아무도 직접 읽거나 쓰지 못하고, 아래 두 함수로만 다뤄요 (누가 눌렀는지는 공개되지 않아요)
revoke all on public.votes from public, anon, authenticated;

-- 내 표를 통째로 맞추기: {"mole":1,"maze":-1} 처럼 보내면 그대로 저장
create or replace function public.sync_votes(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'bad input'; end if;
  delete from votes where user_id = auth.uid() and not (p ? game_id);
  insert into votes (user_id, game_id, v)
    select auth.uid(), e.key, (e.value #>> '{}')::smallint
    from jsonb_each(p) e
    where e.value #>> '{}' in ('1', '-1') and char_length(e.key) <= 40
    limit 200
  on conflict (user_id, game_id) do update set v = excluded.v, updated_at = now();
end $$;
revoke all on function public.sync_votes(jsonb) from public, anon;
grant execute on function public.sync_votes(jsonb) to authenticated;

-- 게임별 좋아요·싫어요 수 (로그인 안 해도 볼 수 있어요)
create or replace function public.vote_counts()
returns table (game_id text, up bigint, down bigint)
language sql stable security definer set search_path = public as $$
  select game_id, count(*) filter (where v = 1), count(*) filter (where v = -1)
  from votes group by game_id;
$$;
revoke all on function public.vote_counts() from public;
grant execute on function public.vote_counts() to anon, authenticated;
