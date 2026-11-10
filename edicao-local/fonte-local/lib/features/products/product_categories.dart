/// Shared by the existing product form and the operations catalog.
const productCategories = <String, List<String>>{
  'Químicos e minerais': [
    'Fertilizantes e adubos minerais',
    'Corretivos de solo',
    'Herbicidas',
    'Inseticidas',
    'Fungicidas',
    'Nematicidas',
    'Acaricidas',
    'Bactericidas',
    'Adjuvantes',
  ],
  'Biológicos e orgânicos': [
    'Bioinsumos e inoculantes',
    'Biofertilizantes',
    'Compostos orgânicos',
    'Controle biológico',
    'Bioestimulantes',
  ],
  'Sementes e material genético': [
    'Sementes',
    'Mudas',
    'Sêmen',
    'Embriões',
  ],
  'Peças e materiais de máquinas e implementos': [
    'Peças de reposição',
    'Filtros',
    'Pneus',
    'Correias e mangueiras',
    'Bicos e componentes de aplicação',
    'Ferramentas e materiais de manutenção',
  ],
  'Insumos pecuários': [
    'Rações',
    'Sais minerais',
    'Volumosos',
    'Suplementos',
    'Vacinas',
    'Vermífugos',
    'Medicamentos veterinários',
  ],
  'Tecnologia e irrigação': [
    'Sensores e componentes eletrônicos',
    'Materiais de irrigação',
    'Água',
  ],
  'Combustíveis e lubrificantes': [
    'Diesel',
    'Gasolina',
    'Etanol',
    'Óleos lubrificantes',
    'Graxas',
  ],
  'Outros materiais': ['Equipamentos de proteção', 'Embalagens', 'Outros'],
};

String productClassification(String category, String type) => [
      category.isEmpty ? 'Sem categoria informada' : category,
      type
    ].where((value) => value.isNotEmpty).join(' · ');
