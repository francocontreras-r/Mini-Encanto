-- ============================================================================
-- Mini Encanto — Etapa D: Compras y Proveedores (versión simple)
-- ----------------------------------------------------------------------------
-- Proveedores + compras que SUMAN stock directo (sin órdenes, sin deuda, sin
-- recepciones parciales). La compra es ATÓMICA y auditada, y actualiza el
-- costo del producto con el último costo de compra.
--
-- Seguro: crea objetos nuevos, no borra ni modifica datos existentes.
-- Requiere haber corrido antes rls_por_rol.sql (usa mi_rol()).
-- Pegar COMPLETO en Supabase → SQL Editor → Run. Es idempotente.
-- ============================================================================

-- 1) Tablas
create table if not exists public.proveedores (
  id text primary key,
  nombre text not null,
  telefono text,
  email text,
  notas text,
  creado timestamptz default now()
);

create table if not exists public.compras (
  id text primary key,
  fecha timestamptz not null default now(),
  proveedor_id text,
  proveedor_nombre text,
  total_costo numeric default 0,
  items_count int default 0,
  unidades int default 0,
  usuario text,
  notas text
);

create table if not exists public.items_compra (
  id bigserial primary key,
  compra_id text references public.compras(id),
  producto_id text,
  variante_id text,
  nombre text,
  talle text,
  qty numeric,
  costo_unit numeric
);

-- 2) RLS: todos leen; solo admin escribe (las compras entran por la RPC).
do $$
declare t text; tablas text[] := array['proveedores','compras','items_compra'];
begin
  foreach t in array tablas loop
    execute format('alter table public.%I enable row level security;', t);
    execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_sel', t);
    execute format('create policy %I on public.%I for select to authenticated using (true);', 'me_'||t||'_sel', t);
    execute format('drop policy if exists %I on public.%I;', 'me_'||t||'_wadmin', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.mi_rol()=''admin'') with check (public.mi_rol()=''admin'');', 'me_'||t||'_wadmin', t);
  end loop;
end $$;

-- 3) RPC: registrar_compra (atómica, solo admin)
create or replace function public.registrar_compra(
  p_proveedor_id text, p_proveedor_nombre text, p_items jsonb,
  p_notas text default '', p_actualizar_costo boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text; v_item jsonb; v_total numeric := 0; v_unid int := 0; v_cnt int := 0;
  v_var record; v_prod record; v_nuevo numeric; v_qty numeric; v_costo numeric;
begin
  if public.mi_rol() <> 'admin' then raise exception 'No autorizado'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'La compra no tiene items'; end if;

  v_id := 'CMP' || (extract(epoch from now())*1000)::bigint;
  insert into compras (id, fecha, proveedor_id, proveedor_nombre, usuario, notas)
  values (v_id, now(), p_proveedor_id, p_proveedor_nombre, (auth.jwt() ->> 'email'), p_notas);

  for v_item in select value from jsonb_array_elements(p_items) as t(value) loop
    v_qty   := coalesce((v_item->>'qty')::numeric, 0);
    v_costo := coalesce((v_item->>'costo')::numeric, 0);
    if v_qty <= 0 then continue; end if;

    select * into v_var from variantes where id = (v_item->>'variante_id') for update;
    if not found then raise exception 'Variante inexistente: %', (v_item->>'variante_id'); end if;
    select * into v_prod from productos where id = v_var.producto_id;

    v_nuevo := coalesce(v_var.stock,0) + v_qty;
    update variantes set stock = v_nuevo where id = v_var.id;

    insert into movimientos (tipo, producto, producto_id, talle, qty, motivo, usuario, fecha)
    values ('ingreso', v_prod.nombre, v_prod.id::text, v_var.talle, v_qty,
            'Compra '||coalesce(p_proveedor_nombre,''), (auth.jwt() ->> 'email'), now());

    insert into items_compra (compra_id, producto_id, variante_id, nombre, talle, qty, costo_unit)
    values (v_id, v_prod.id::text, v_var.id, v_prod.nombre, v_var.talle, v_qty, v_costo);

    if p_actualizar_costo and v_costo > 0 then
      update productos set costo = v_costo where id = v_prod.id;
    end if;

    v_total := v_total + v_qty * v_costo;
    v_unid  := v_unid + v_qty;
    v_cnt   := v_cnt + 1;
  end loop;

  update compras set total_costo = v_total, unidades = v_unid, items_count = v_cnt where id = v_id;

  insert into auditoria (usuario, accion, entidad, entidad_id, detalle)
  values ((auth.jwt() ->> 'email'), 'compra', 'compra', v_id,
          jsonb_build_object('proveedor', p_proveedor_nombre, 'total', v_total, 'unidades', v_unid, 'items', v_cnt));

  return jsonb_build_object('id', v_id, 'total', v_total, 'unidades', v_unid, 'items', v_cnt);
end; $$;
grant execute on function public.registrar_compra(text,text,jsonb,text,boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- ROLLBACK (si hiciera falta):
--   drop function if exists public.registrar_compra(text,text,jsonb,text,boolean);
--   drop table if exists public.items_compra;
--   drop table if exists public.compras;
--   drop table if exists public.proveedores;
-- ============================================================================
