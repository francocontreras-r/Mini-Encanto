-- ============================================================================
-- Mini Encanto — Etapa B: RPCs atómicas de stock + auditoría
-- ----------------------------------------------------------------------------
-- Hace que INGRESO y BAJA de stock sean operaciones ATÓMICAS en el servidor
-- (bloquean la fila, ajustan stock, registran el movimiento y la auditoría en
-- UNA transacción), evitando que dos personas pisen el stock a la vez.
-- Además crea una tabla de AUDITORÍA de cambios críticos.
--
-- Seguro: crea objetos nuevos, no borra ni modifica datos existentes.
-- Pegar COMPLETO en Supabase → SQL Editor → Run. Es idempotente.
-- Requiere haber corrido antes rls_por_rol.sql (usa la función mi_rol()).
-- ============================================================================

-- 1) Tabla de auditoría (quién hizo qué y cuándo)
create table if not exists public.auditoria (
  id         bigserial primary key,
  fecha      timestamptz not null default now(),
  usuario    text,
  accion     text not null,       -- 'ingreso', 'baja', ...
  entidad    text,                -- 'variante', 'producto', ...
  entidad_id text,
  detalle    jsonb
);
alter table public.auditoria enable row level security;
drop policy if exists me_auditoria_sel on public.auditoria;
-- Solo admin puede LEER la auditoría. La ESCRITURA ocurre solo vía las RPCs
-- (SECURITY DEFINER), nunca directa, así que no hace falta policy de insert.
create policy me_auditoria_sel on public.auditoria
  for select to authenticated using (public.mi_rol() = 'admin');

-- 2) RPC: registrar_ingreso (atómica, solo admin)
create or replace function public.registrar_ingreso(
  p_variante_id text, p_qty numeric, p_motivo text default 'Ingreso manual'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_var record; v_prod record; v_nuevo numeric;
begin
  if public.mi_rol() <> 'admin' then raise exception 'No autorizado'; end if;
  if coalesce(p_qty,0) <= 0 then raise exception 'Cantidad inválida'; end if;

  select * into v_var from variantes where id = p_variante_id for update;
  if not found then raise exception 'Variante inexistente'; end if;
  select * into v_prod from productos where id = v_var.producto_id;

  v_nuevo := coalesce(v_var.stock,0) + p_qty;
  update variantes set stock = v_nuevo where id = p_variante_id;

  insert into movimientos (tipo, producto, producto_id, talle, qty, motivo, usuario, fecha)
  values ('ingreso', v_prod.nombre, v_prod.id::text, v_var.talle, p_qty, p_motivo,
          (auth.jwt() ->> 'email'), now());

  insert into auditoria (usuario, accion, entidad, entidad_id, detalle)
  values ((auth.jwt() ->> 'email'), 'ingreso', 'variante', p_variante_id,
          jsonb_build_object('qty', p_qty, 'stock_nuevo', v_nuevo, 'motivo', p_motivo));

  return jsonb_build_object('stock', v_nuevo);
end; $$;
grant execute on function public.registrar_ingreso(text,numeric,text) to authenticated;

-- 3) RPC: registrar_baja (atómica, solo admin)
create or replace function public.registrar_baja(
  p_variante_id text, p_qty numeric, p_motivo text, p_obs text default ''
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_var record; v_prod record; v_nuevo numeric;
begin
  if public.mi_rol() <> 'admin' then raise exception 'No autorizado'; end if;
  if coalesce(p_qty,0) <= 0 then raise exception 'Cantidad inválida'; end if;

  select * into v_var from variantes where id = p_variante_id for update;
  if not found then raise exception 'Variante inexistente'; end if;
  select * into v_prod from productos where id = v_var.producto_id;

  v_nuevo := greatest(0, coalesce(v_var.stock,0) - p_qty);
  update variantes set stock = v_nuevo where id = p_variante_id;

  insert into movimientos (tipo, producto, producto_id, talle, qty, motivo, usuario, fecha)
  values ('baja', v_prod.nombre, v_prod.id::text, v_var.talle, p_qty,
          p_motivo || case when coalesce(p_obs,'') <> '' then ' — '||p_obs else '' end,
          (auth.jwt() ->> 'email'), now());

  insert into bajas (producto_id, nombre, motivo, qty, obs)
  values (v_prod.id, v_prod.nombre, p_motivo, p_qty, p_obs);

  insert into auditoria (usuario, accion, entidad, entidad_id, detalle)
  values ((auth.jwt() ->> 'email'), 'baja', 'variante', p_variante_id,
          jsonb_build_object('qty', p_qty, 'stock_nuevo', v_nuevo, 'motivo', p_motivo, 'obs', p_obs));

  return jsonb_build_object('stock', v_nuevo);
end; $$;
grant execute on function public.registrar_baja(text,numeric,text,text) to authenticated;

-- ----------------------------------------------------------------------------
-- ROLLBACK (si hiciera falta):
--   drop function if exists public.registrar_ingreso(text,numeric,text);
--   drop function if exists public.registrar_baja(text,numeric,text,text);
--   drop table if exists public.auditoria;
-- ============================================================================
