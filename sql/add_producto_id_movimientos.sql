-- ============================================================================
-- Mini Encanto — Etapa C: producto_id en movimientos
-- ----------------------------------------------------------------------------
-- Hoy la tabla movimientos referencia al producto POR NOMBRE. Si se renombra
-- un producto, su historial (y la ficha de stock) se desvincula. Esto agrega
-- una columna producto_id y la rellena a partir del nombre actual.
--
-- SEGURO Y REVERSIBLE: no borra ni modifica datos existentes (solo agrega una
-- columna nueva y la completa). Pegar COMPLETO en Supabase → SQL Editor → Run.
-- ============================================================================

-- 1) Nueva columna (si no existe)
alter table public.movimientos add column if not exists producto_id text;

-- 2) Backfill: completar producto_id por nombre exacto, solo donde está vacío
update public.movimientos m
set producto_id = p.id::text
from public.productos p
where m.producto_id is null
  and m.producto = p.nombre;

-- 3) Índice para acelerar la ficha de stock por producto
create index if not exists idx_movimientos_producto_id
  on public.movimientos(producto_id);

-- 4) Verificación (opcional): cuántos movimientos quedaron sin vincular
--    (suele ser por productos renombrados o borrados; no es un error).
--   select count(*) as sin_vincular from public.movimientos where producto_id is null;

-- ----------------------------------------------------------------------------
-- ROLLBACK (si hiciera falta deshacer):
--   drop index if exists public.idx_movimientos_producto_id;
--   alter table public.movimientos drop column if exists producto_id;
-- ============================================================================
