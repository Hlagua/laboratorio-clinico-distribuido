import { Component, computed, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { hoyIso } from '../core/formato';
import { Laboratorio } from '../core/modelos';

/** Turnos de toma de muestras de cada sucursal (lunes a sábado). Los de los médicos se arman en "Horarios de médicos". */
@Component({
  selector: 'app-franjas',
  imports: [FormsModule],
  template: `
    <h1>Turnos de toma de muestras</h1>
    <p class="sub">Cada sucursal tiene sus turnos. El paciente los ve en un calendario de hasta 3 meses al pedir sus
      exámenes. Lunes a sábado; los turnos que ya existen no se duplican.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }

    <form class="card" (ngSubmit)="generar()">
      <div class="campo"><label for="fs">Sucursal</label>
        <select id="fs" name="fs" [(ngModel)]="fr.laboratorio_id">
          @for (l of sucursales(); track l.laboratorio_id) { <option [ngValue]="l.laboratorio_id">{{ l.nombre }}</option> }
        </select></div>
      <div class="fila">
        <div class="campo"><label for="fd">Desde</label><input id="fd" type="date" name="d" [min]="hoy" [(ngModel)]="fr.desde" required /></div>
        <div class="campo"><label for="fh">Hasta (máx. 3 meses)</label><input id="fh" type="date" name="h" [min]="fr.desde" [(ngModel)]="fr.hasta" required /></div>
      </div>
      <div class="fila">
        <div class="campo"><label for="fi">Hora inicio</label><input id="fi" type="time" name="hi" [(ngModel)]="fr.hora_inicio" /></div>
        <div class="campo"><label for="ff">Hora fin</label><input id="ff" type="time" name="hf" [(ngModel)]="fr.hora_fin" /></div>
        <div class="campo"><label for="fm">Minutos por turno</label><input id="fm" type="number" min="10" max="120" name="im" [(ngModel)]="fr.intervalo_minutos" /></div>
        <div class="campo"><label for="fc">Pacientes por turno</label><input id="fc" type="number" min="1" max="20" name="cp" [(ngModel)]="fr.capacidad" /></div>
      </div>
      <button type="submit" [disabled]="!fr.laboratorio_id">Generar turnos</button>
    </form>
  `,
})
export class Franjas implements OnInit {
  private readonly api = inject(Api);
  protected readonly hoy = hoyIso();
  protected readonly labs = signal<Laboratorio[]>([]);
  protected readonly sucursales = computed(() => this.labs().filter((l) => l.propio && l.activo));
  protected fr = { laboratorio_id: null as number | null, desde: hoyIso(), hasta: new Date(Date.now() + 30 * 86_400_000).toISOString().slice(0, 10),
    hora_inicio: '07:00', hora_fin: '11:00', intervalo_minutos: 30, capacidad: 3 };
  protected readonly error = signal('');
  protected readonly aviso = signal('');

  async ngOnInit() {
    try {
      this.labs.set(await this.api.get<Laboratorio[]>('/api/laboratorios'));
      this.fr.laboratorio_id = this.sucursales()[0]?.laboratorio_id ?? null;
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async generar() {
    this.error.set('');
    this.aviso.set('');
    try {
      const r = await this.api.post<{ franjas_creadas: number }>('/api/citas/franjas', this.fr);
      const s = this.sucursales().find((l) => l.laboratorio_id === this.fr.laboratorio_id);
      this.aviso.set(`${r.franjas_creadas} turnos creados en ${s?.nombre ?? 'la sucursal'}.`);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }
}
