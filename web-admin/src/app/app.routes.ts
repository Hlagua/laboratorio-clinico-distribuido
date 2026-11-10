import { Routes } from '@angular/router';
import { autenticado, conRol } from './core/guards';

export const routes: Routes = [
  { path: 'login', loadComponent: () => import('./paginas/login').then((m) => m.Login) },
  { path: 'inicio', canActivate: [autenticado], loadComponent: () => import('./paginas/inicio').then((m) => m.Inicio) },
  { path: 'agenda', canActivate: [autenticado], loadComponent: () => import('./paginas/agenda').then((m) => m.Agenda) },
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
  {
    path: 'conocimiento', canActivate: [conRol('MEDICO', 'ADMIN')],
    loadComponent: () => import('./paginas/conocimiento').then((m) => m.Conocimiento),
  },
  { path: 'reportes', canActivate: [conRol('ADMIN', 'MEDICO')], loadComponent: () => import('./paginas/reportes').then((m) => m.Reportes) },
  { path: 'auditoria', canActivate: [conRol('ADMIN')], loadComponent: () => import('./paginas/auditoria').then((m) => m.Auditoria) },
  { path: '', pathMatch: 'full', redirectTo: 'inicio' },
  { path: '**', redirectTo: 'inicio' },
];
