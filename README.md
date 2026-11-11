# COTA · Escuela de nieve

Planificación diaria de esquí y snowboard: agenda, cupos, alquileres, reubicación por viento y honorarios. Español argentino, catálogo 2026 en ARS y datos sintéticos.

**Estado:** conectado a un proyecto propio **Supabase Free**, con tres cuentas Auth activas. Las pruebas de roles, aislamiento por IDs y concurrencia remota pasan. Solo hay datos sintéticos.

## Ingreso de prueba

La contraseña de las tres cuentas se entrega por separado en la conversación. No se publica en este repositorio. Son cuentas de demostración; no las uses con información real.

| Cuenta | Rol |
| --- | --- |
| `coordinacion@cota.test` | Toda la operación y finanzas |
| `recepcion@cota.test` | Alumnos, clases, inscripciones, equipos y cobro manual |
| `instructor@cota.test` | Solo clases de Lara Lagos y marcarlas dictadas |

Sin confirmación de correo, registro público en la app ni recuperación por email. Los roles se asignan en la base, nunca desde el formulario.

## Ejecutar

Node.js 22 o superior:

```sh
npm ci
npm run build
npm run dev
```

Abrí `http://localhost:3000`. Sin variables se muestra **DEMO LOCAL**, con datos del **14/08/2026**. Usa PostgreSQL embebido (PGlite) y guarda los cambios solo en ese navegador. El perfil de demostración es fijo; no hay selección pública de roles.

## Activar Supabase

1. Creá tu proyecto propio en el plan Free.
2. Ejecutá los archivos de `supabase/migrations/` en orden y luego `supabase/seed.sql`, una vez sobre la base nueva.
3. Deshabilitá registro público y confirmación por correo en Auth.
4. Copiá `.env.example` a `.env` y completá tus valores. Nunca subas `.env`. La clave `service_role` es exclusiva de la terminal.
5. Ejecutá `npm run seed:auth` para crear las cuentas confirmadas, sin emails. Después: `node --env-file=.env scripts/build.mjs`.

Para otra instalación, la contraseña será tu valor de `DEMO_PASSWORD`. El script administrativo crea cuentas confirmadas y perfiles sin enviar correos.

## Decisiones principales

- **Validador único SQL:** `validate_class` devuelve reglas incumplidas y mensajes. Se comparte entre alta, edición y reubicación. Cupos por intervalo, margen de 30 minutos y habilitaciones verificadas en base de datos.
- **RLS en todas las tablas:** un rol por perfil. Sin escrituras directas del navegador ni acceso de recepción a finanzas. Cambiar un identificador no amplía los permisos.
- **Operaciones atómicas:** bloqueo transaccional, versiones e idempotencia. Una confirmación repetida no vuelve a consumir stock o plazas.
- **Operación diaria:** espera FIFO, aviso por WhatsApp, cierres por viento, asistencia, cobro manual y honorarios solo de clases dictadas. Sin pagos reales, mapas ni emails.

## Verificar

```sh
npm test              # 22 pruebas SQL/RLS locales
npm run test:remote   # Auth y concurrencia, después de conectar Supabase
```

Las 22 pruebas locales y el ensayo remoto pasan. El ensayo remoto comprueba Auth de los tres roles y dos solicitudes simultáneas sobre la última plaza y la última unidad de equipo. [Instalación, reglas y límites](docs/IMPLEMENTACION.md).

Código: `web/` · Base y RLS: `supabase/` · Cuentas: `scripts/seed-auth.mjs` · Pruebas: `tests/`.
