import { Component, computed, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { hoyIso } from '../core/formato';
import { Descuento, Laboratorio, TipoExamen } from '../core/modelos';

/**
 * Descuentos: por sucursal (o en todas), por examen (o en todos) y por fechas.
 * Se aplican al crear la solicitud (y si el paciente cambia de sucursal antes de pagar): gana el mayor vigente.
 */
@Component({
  selector: 'app-descuentos',
  imports: [FormsModule],
  template: `
    <h1>Descuentos</h1>
    <p class="sub">Promociones por sucursal, por examen y por fechas. El paciente ve el precio anterior y el porcentaje
      en el resumen de su pedido. Si varios aplican, se usa el mayor.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }

    <div class="card tabla-scroll">
      <table>
        <thead><tr><th>Descuento</th><th class="num">%</th><th>Sucursal</th><th>Examen</th><th>Vigencia</th><th>Estado</th></tr></thead>
        <tbody>
          @for (d of descuentos(); track d.descuento_id) {
            <tr [class.inactiva]="!vigente(d)">
              <td><strong>{{ d.nombre }}</strong></td>
              <td class="num">{{ d.porcentaje }} %</td>
              <td>{{ d.sucursal ?? 'Todas' }}</td>
              <td>{{ d.examen ?? 'Todos' }}</td>
              <td>{{ d.desde }} a {{ d.hasta }}</td>
              <td><span [class]="vigente(d) ? 'badge' : 'badge gris'">{{ estado(d) }}</span>
                <button class="secundario chico" (click)="activar(d)">{{ d.activo ? 'Desactivar' : 'Activar' }}</button></td>
            </tr>
          } @empty { <tr><td colspan="6" class="vacio">Aún no hay descuentos.</td></tr> }
        </tbody>
      </table>
    </div>

    <form class="card" (ngSubmit)="crear()">
      <h2>Nuevo descuento</h2>
      <div class="fila">
        <div class="campo" style="flex: 2"><label for="dn">Nombre</label><input id="dn" name="dn" maxlength="120" [(ngModel)]="n.nombre" placeholder="Mes del corazón" required /></div>
        <div class="campo"><label for="dp">Porcentaje</label><input id="dp" name="dp" type="number" min="1" max="90" [(ngModel)]="n.porcentaje" required /></div>
      </div>
      <div class="fila">
        <div class="campo"><label for="ds">Sucursal</label>
          <select id="ds" name="ds" [(ngModel)]="n.laboratorio_id">
            <option [ngValue]="null">Todas las sucursales</option>
            @for (l of sucursales(); track l.laboratorio_id) { <option [ngValue]="l.laboratorio_id">{{ l.nombre }}</option> }
          </select></div>
        <div class="campo"><label for="de">Examen</label>
          <select id="de" name="de" [(ngModel)]="n.tipo_examen_id">
            <option [ngValue]="null">Todos los exámenes</option>
            @for (t of examenes(); track t.tipo_examen_id) { <option [ngValue]="t.tipo_examen_id">{{ t.nombre }}</option> }
          </select></div>
      </div>
      <div class="fila">
        <div class="campo"><label for="dd">Desde</label><input id="dd" name="dd" type="date" [(ngModel)]="n.desde" required /></div>
        <div class="campo"><label for="dh">Hasta</label><input id="dh" name="dh" type="date" [min]="n.desde" [(ngModel)]="n.hasta" required /></div>
      </div>
      <button type="submit" [disabled]="!n.nombre.trim() || !n.porcentaje">Crear descuento</button>
    </form>
  `,
  styles: `tr.inactiva td { opacity: .55; } .badge { margin-right: 6px; }`,
})
export class Descuentos implements OnInit {
  private readonly api = inject(Api);
  protected readonly descuentos = signal<Descuento[]>([]);
  protected readonly labs = signal<Laboratorio[]>([]);
  protected readonly sucursales = computed(() => this.labs().filter((l) => l.propio));
  protected readonly examenes = signal<TipoExamen[]>([]);
  protected n = this.vacio();
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  private readonly hoy = hoyIso();

  async ngOnInit() {
    try {
      const [labs, examenes] = await Promise.all([
        this.api.get<Laboratorio[]>('/api/laboratorios'),
        this.api.get<TipoExamen[]>('/api/examenes/catalogo'),
      ]);
      this.labs.set(labs);
      this.examenes.set(examenes.filter((t) => t.codigo !== 'CONS-MED'));
      await this.cargar();
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  private vacio() {
    return { nombre: '', porcentaje: 10 as number | null, laboratorio_id: null as number | null, tipo_examen_id: null as number | null,
      desde: hoyIso(), hasta: new Date(Date.now() + 30 * 86_400_000).toISOString().slice(0, 10) };
  }

  private async cargar() {
    this.descuentos.set(await this.api.get<Descuento[]>('/api/descuentos', { todos: 1 }));
  }

  protected vigente(d: Descuento) {
    return d.activo && d.desde <= this.hoy && this.hoy <= d.hasta;
  }

  protected estado(d: Descuento) {
    if (!d.activo) return 'inactivo';
    if (d.hasta < this.hoy) return 'vencido';
    if (d.desde > this.hoy) return 'programado';
    return 'vigente';
  }

  protected async crear() {
    await this.paso(async () => {
      await this.api.post('/api/descuentos', this.n);
      this.n = this.vacio();
    }, 'Descuento creado.');
  }

  protected async activar(d: Descuento) {
    await this.paso(() => this.api.patch(`/api/descuentos/${d.descuento_id}`, { activo: !d.activo }), '');
  }

  private async paso(fn: () => Promise<unknown>, exito: string) {
    this.error.set('');
    this.aviso.set('');
    try {
      await fn();
      if (exito) this.aviso.set(exito);
      await this.cargar();
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }
}
