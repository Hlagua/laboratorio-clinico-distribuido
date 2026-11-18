import { Component, inject, OnInit, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Api, mensajeError } from '../core/api';
import { AuthService, NOMBRE_ROL } from '../core/auth';
import { hoyIso } from '../core/formato';
import { Cita, SolicitudResumen, Tratamiento } from '../core/modelos';

interface Indicador { titulo: string; valor: number | string; detalle: string; ruta: string }

@Component({
  selector: 'app-inicio',
  imports: [RouterLink],
  template: `
    <h1>Hola, {{ auth.usuario()?.nombre }}</h1>
    <p class="sub">Está trabajando como <strong>{{ nombreRol[auth.rolActivo()!] }}</strong>.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    <div class="grid">
      @for (i of indicadores(); track i.titulo) {
        <a class="card enlace" [routerLink]="i.ruta">
          <div class="muted">{{ i.titulo }}</div>
          <div class="kpi">{{ i.valor }}</div>
          <small class="muted">{{ i.detalle }}</small>
        </a>
      } @empty {
        <div class="card muted">Cargando indicadores…</div>
      }
    </div>
  `,
  styles: `.enlace { text-decoration: none; color: inherit; display: block; } .enlace:hover { border-color: var(--verde); }`,
})
export class Inicio implements OnInit {
  protected readonly auth = inject(AuthService);
  private readonly api = inject(Api);
  protected readonly nombreRol = NOMBRE_ROL;
  protected readonly indicadores = signal<Indicador[]>([]);
  protected readonly error = signal('');

  async ngOnInit() {
    try {
      // Todas las consultas en paralelo: antes se hacían una tras otra y "Cargando indicadores…" tardaba.
      const medico = this.auth.tiene('MEDICO');
      const [pagadas, enProceso, agenda, listos, trat, pendientes] = await Promise.all([
        this.api.get<SolicitudResumen[]>('/api/solicitudes', { estado: 'PAGADA', tipo: 'EXAMENES' }),
        this.api.get<SolicitudResumen[]>('/api/solicitudes', { estado: 'EN_PROCESO', tipo: 'EXAMENES' }),
        this.api.get<Cita[]>('/api/citas/agenda', { fecha: hoyIso() }),
        medico ? this.api.get<SolicitudResumen[]>('/api/solicitudes', { estado: 'COMPLETADA', propias: 1, tipo: 'EXAMENES' })
          : Promise.resolve([]),
        this.auth.tiene('MEDICO', 'ADMIN') ? this.api.get<Tratamiento[]>('/api/tratamientos') : Promise.resolve([]),
        this.auth.tiene('ADMIN') ? this.api.get<unknown[]>('/api/pagos', { estado: 'PENDIENTE' }) : Promise.resolve([]),
      ]);
      const lista: Indicador[] = [{
        titulo: medico ? 'Mis consultas de hoy' : 'Citas de hoy', valor: agenda.length,
        detalle: medico ? 'Pacientes por atender' : this.auth.tiene('LABORATORISTA') ? 'Turnos de toma de muestras'
          : 'Consultas y tomas de muestras', ruta: '/agenda',
      }];
      if (medico) {
        lista.push({ titulo: 'Resultados de mis pacientes', valor: listos.length, detalle: 'Exámenes que ordenó, ya completos',
          ruta: '/solicitudes' });
      }
      lista.push({ titulo: 'Solicitudes por procesar', valor: pagadas.length + enProceso.length,
        detalle: `${pagadas.length} pagadas · ${enProceso.length} en proceso`, ruta: '/solicitudes' });
      if (this.auth.tiene('MEDICO', 'ADMIN')) {
        lista.push({ titulo: medico ? 'Mis tratamientos activos' : 'Tratamientos activos',
          valor: trat.filter((t) => t.estado === 'ACTIVO').length, detalle: 'Seguimiento médico', ruta: '/pacientes' });
      }
      if (this.auth.tiene('ADMIN')) {
        lista.push({ titulo: 'Pagos pendientes', valor: pendientes.length, detalle: 'Pagos con Stripe sin confirmar', ruta: '/pagos' });
      }
      this.indicadores.set(lista);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

}
