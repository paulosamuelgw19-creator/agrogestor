"""Validated logistics contracts; no conversion of existing hours into km."""
from datetime import date, datetime, timezone
from typing import Literal
from uuid import UUID
import re

from pydantic import AwareDatetime, Field, model_validator, field_validator
from .v2_models import Body, Name, Positive, NonNegative, Money

Unit = Literal['kg', 't', 'L', 'un', 'saca', 'caixa', 'm3']
Status = Literal['scheduled', 'loading', 'in_transit', 'delivered', 'cancelled']
Category = Literal['fuel', 'toll', 'daily', 'food', 'lodging', 'freight', 'maintenance', 'other']


class CarrierBody(Body):
    id: UUID
    name: Name
    phone: str = Field(default='', max_length=80)
    notes: str = Field(default='', max_length=2000)


class TruckBody(Body):
    # Same identity as v2_machines; creating a road profile is not a new machine.
    id: UUID
    plate: str = Field(min_length=1, max_length=20)
    brand: str = Field(default='', max_length=100)
    model: str = Field(default='', max_length=100)
    year: int | None = Field(default=None, strict=True, ge=1900, le=2200)
    vehicle_type: Name
    capacity: Positive | None = None
    capacity_unit: Unit | None = None
    odometer_km: NonNegative | None = None
    ownership: Literal['own', 'contracted']
    carrier_id: UUID | None = None
    per_km_cents: Money | None = None
    rate_components: list[Category] = Field(default_factory=list, max_length=8)
    notes: str = Field(default='', max_length=2000)

    @field_validator('plate')
    @classmethod
    def normalized_plate(cls, value):
        value = re.sub(r'[\s-]', '', value).upper()
        if not re.fullmatch(r'[A-Z0-9]{2,12}', value):
            raise ValueError('Informe uma placa válida, sem símbolos.')
        return value

    @model_validator(mode='after')
    def coherent(self):
        if (self.capacity is None) != (self.capacity_unit is None):
            raise ValueError('Informe capacidade e unidade juntas.')
        if self.ownership == 'contracted' and self.carrier_id is None:
            raise ValueError('O veículo terceirizado precisa de uma transportadora.')
        if len(set(self.rate_components)) != len(self.rate_components):
            raise ValueError('Os componentes da tarifa não podem se repetir.')
        if self.per_km_cents is None and self.rate_components:
            raise ValueError('Informe a tarifa correspondente aos componentes.')
        return self


class DriverBody(CarrierBody):
    employment: Literal['employee', 'independent', 'carrier']
    carrier_id: UUID | None = None
    user_id: str | None = Field(default=None, min_length=1, max_length=160)
    license_category: str = Field(default='', max_length=20)
    license_expires_on: date | None = None

    @model_validator(mode='after')
    def coherent(self):
        if self.employment == 'carrier' and self.carrier_id is None:
            raise ValueError('Informe a transportadora do caminhoneiro.')
        return self


class ArchiveBody(Body):
    id: UUID
    expected_version: int = Field(strict=True, ge=1)
    archived: bool = Field(strict=True)
    reason: str = Field(min_length=1, max_length=2000)


class CargoBody(Body):
    id: UUID
    name: Name
    kind: Literal['coffee', 'grain', 'input', 'machine', 'other']
    input_id: UUID | None = None
    unit: Unit
    planned_quantity: Positive | None = None
    # Optional, explicitly supplied factor. A coffee sack has no implied weight.
    tonnes_per_unit: Positive | None = None

    @model_validator(mode='after')
    def coherent(self):
        if self.input_id is not None and self.kind != 'input':
            raise ValueError('Vincule produtos de estoque somente a cargas de insumos.')
        if self.unit == 't' and self.tonnes_per_unit not in (None, 1):
            raise ValueError('Uma tonelada corresponde a uma tonelada.')
        return self


class TripBody(Body):
    id: UUID
    name: Name
    truck_id: UUID
    driver_id: UUID
    transport_mode: Literal['own', 'contracted']
    property_id: UUID
    plot_id: UUID | None = None
    operation_id: UUID | None = None
    origin: Name
    destination: Name
    planned_departure_at: AwareDatetime
    planned_arrival_at: AwareDatetime
    contracted_freight_cents: Money | None = None
    cargo: list[CargoBody] = Field(min_length=1, max_length=30)
    notes: str = Field(default='', max_length=2000)

    @model_validator(mode='after')
    def coherent(self):
        if self.planned_arrival_at < self.planned_departure_at:
            raise ValueError('A chegada prevista não pode anteceder a saída.')
        if self.transport_mode == 'own' and self.contracted_freight_cents is not None:
            raise ValueError('Frete contratado pertence ao transporte terceirizado.')
        if len({c.id for c in self.cargo}) != len(self.cargo):
            raise ValueError('Cada carga precisa de um identificador diferente.')
        return self


class CargoActual(Body):
    cargo_id: UUID
    loaded_quantity: NonNegative | None = None
    delivered_quantity: NonNegative | None = None


class TripProgress(Body):
    id: UUID
    expected_version: int = Field(strict=True, ge=1)
    status: Status
    description: str = Field(min_length=1, max_length=4000)
    occurred_at: AwareDatetime
    start_km: NonNegative | None = None
    end_km: NonNegative | None = None
    cargo: list[CargoActual] = Field(default_factory=list, max_length=30)
    attachments: list[UUID] = Field(default_factory=list, max_length=20)

    @model_validator(mode='after')
    def coherent(self):
        if self.end_km is not None and self.start_km is not None and self.end_km < self.start_km:
            raise ValueError('A quilometragem final não pode ser menor que a inicial.')
        if len({c.cargo_id for c in self.cargo}) != len(self.cargo):
            raise ValueError('Não repita a mesma carga no andamento.')
        if len(set(self.attachments)) != len(self.attachments):
            raise ValueError('Não repita comprovantes.')
        if self.occurred_at > datetime.now(timezone.utc):
            raise ValueError('O acontecimento não pode estar no futuro.')
        return self


class PropertyAllocation(Body):
    id: UUID
    property_id: UUID
    operation_id: UUID | None = None
    amount_cents: Money


class CargoAllocation(Body):
    cargo_id: UUID
    amount_cents: Money


class ExpenseBody(Body):
    id: UUID
    category: Category
    description: str = Field(min_length=1, max_length=2000)
    amount_cents: Money | None = None
    source_kind: Literal['manual', 'refueling', 'maintenance', 'road_refueling'] = 'manual'
    source_id: UUID | None = None
    occurred_on: date
    allocations: list[PropertyAllocation] = Field(default_factory=list, max_length=100)
    cargo_allocations: list[CargoAllocation] = Field(default_factory=list, max_length=30)

    @model_validator(mode='after')
    def coherent(self):
        if (self.source_kind == 'manual') != (self.source_id is None):
            raise ValueError('Identifique a origem da despesa vinculada.')
        if self.source_kind in {'refueling', 'road_refueling'} and self.category != 'fuel':
            raise ValueError('Abastecimento deve ser classificado como combustível.')
        if self.source_kind == 'maintenance' and self.category != 'maintenance':
            raise ValueError('A origem de manutenção deve manter essa classificação.')
        if self.source_kind == 'manual' and self.category in {'fuel', 'maintenance'}:
            raise ValueError('Vincule o abastecimento ou a manutenção já registrados.')
        # For a linked source the server resolves the authoritative value and
        # validates these totals again; a client cannot overwrite its cost.
        if self.amount_cents is not None:
            if not self.allocations:
                raise ValueError('Distribua o valor conhecido entre as propriedades atendidas.')
            if sum(a.amount_cents for a in self.allocations) != self.amount_cents:
                raise ValueError('O rateio entre propriedades deve corresponder ao valor da despesa.')
            if self.cargo_allocations and sum(a.amount_cents for a in self.cargo_allocations) != self.amount_cents:
                raise ValueError('O rateio entre cargas deve corresponder ao valor da despesa.')
        elif self.allocations or self.cargo_allocations:
            raise ValueError('O valor não informado não pode ser distribuído como zero ou estimado.')
        if len({a.id for a in self.allocations}) != len(self.allocations):
            raise ValueError('Identificadores de parcelas repetidos.')
        if len({(a.property_id, a.operation_id) for a in self.allocations}) != len(self.allocations):
            raise ValueError('Não repita o mesmo destino no rateio.')
        if len({a.cargo_id for a in self.cargo_allocations}) != len(self.cargo_allocations):
            raise ValueError('Não repita uma carga no rateio.')
        return self
