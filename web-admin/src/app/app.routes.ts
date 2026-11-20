import { Routes } from '@angular/router';
import { autenticado, conRol } from './core/guards';

export const routes: Routes = [
  { path: 'login', loadComponent: () => import('./paginas/login').then((m) => m.Login) },
  { path: 'inicio', canActivate: [autenticado], loadComponent: () => import('./paginas/inicio').then((m) => m.Inicio) },
  { path: 'agenda', canActivate: [conRol('LABORATORISTA', 'MEDICO', 'ADMIN')], loadComponent: () => import('./paginas/agenda').then((m) => m.Agenda) },
  { path: 'horario', canActivate: [conRol('MEDICO', 'ADMIN')], loadComponent: () => import('./paginas/horario').then((m) => m.Horario) },
  { path: 'consulta/:id', canActivate: [conRol('MEDICO')], loadComponent: () => import('./paginas/consulta').then((m) => m.Consulta) },
  { path: 'solicitudes', canActivate: [autenticado], loadComponent: () => import('./paginas/solicitudes').then((m) => m.Solicitudes) },
  {
    path: 'solicitudes/:id', canActivate: [autenticado],
    loadComponent: () => import('./paginas/solicitud-detalle').then((m) => m.SolicitudDetalle),
  },
  {
    path: 'nueva-solicitud', canActivate: [conRol('LABORATORISTA', 'MEDICO')],
    loadComponent: () => import('./paginas/nueva-solicitud').then((m) => m.NuevaSolicitud),
  },
  { path: 'pacientes', canActivate: [autenticado], loadComponent: () => import('./paginas/pacientes').then((m) => m.Pacientes) },
  { path: 'pagos', canActivate: [conRol('ADMIN')], loadComponent: () => import('./paginas/pagos').then((m) => m.Pagos) },
  { path: 'usuarios', canActivate: [conRol('ADMIN')], loadComponent: () => import('./paginas/usuarios').then((m) => m.Usuarios) },
  { path: 'catalogo', canActivate: [conRol('ADMIN')], loadComponent: () => import('./paginas/catalogo').then((m) => m.Catalogo) },
  { path: 'sucursales', canActivate: [conRol('ADMIN')], loadComponent: () => import('./paginas/sucursales').then((m) => m.Sucursales) },
  { path: 'franjas', canActivate: [conRol('ADMIN')], loadComponent: () => import('./paginas/franjas').then((m) => m.Franjas) },
  { path: 'descuentos', canActivate: [conRol('ADMIN')], loadComponent: () => import('./paginas/descuentos').then((m) => m.Descuentos) },
  // Solo el administrador mantiene la base de conocimientos (el médico recibe sus sugerencias al revisar resultados).
  { path: 'conocimiento', pathMatch: 'full', redirectTo: 'conocimiento/reglas' },
  {
    path: 'conocimiento/:seccion', canActivate: [conRol('ADMIN')],
    loadComponent: () => import('./paginas/conocimiento').then((m) => m.Conocimiento),
  },
  { path: 'reportes', canActivate: [conRol('ADMIN', 'MEDICO')], loadComponent: () => import('./paginas/reportes').then((m) => m.Reportes) },
  { path: 'auditoria', canActivate: [conRol('ADMIN')], loadComponent: () => import('./paginas/auditoria').then((m) => m.Auditoria) },
  { path: '', pathMatch: 'full', redirectTo: 'inicio' },
  { path: '**', redirectTo: 'inicio' },
];
