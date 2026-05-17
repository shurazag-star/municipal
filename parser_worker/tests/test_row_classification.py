from municipal_agent.row_classification import (
    DocxRowType,
    ExcelRowType,
    classify_docx_row,
    classify_excel_row,
)


def test_classifies_docx_activity_table_rows():
    assert classify_docx_row(["Итого по подпрограмме", "", "619 636,47"]) == DocxRowType.SUBPROGRAM_TOTAL_ROW
    assert classify_docx_row(["2.1", "Основное мероприятие. Чистая вода", ""]) == DocxRowType.MAIN_ACTIVITY_ROW
    assert classify_docx_row(["2.1.4", "Строительство ВЗУ Черусти", "90 555,38"]) == DocxRowType.OBJECT_ROW
    assert classify_docx_row(["", "Средства бюджета Московской области", "78 330,39"]) == DocxRowType.SOURCE_ROW


def test_classifies_excel_hierarchy_rows():
    assert classify_excel_row({"name": "Муниципальная программа Развитие ЖКХ", "program_code": "01"}) == ExcelRowType.PROGRAM_TOTAL_ROW
    assert classify_excel_row({"name": "Итого:", "program_code": ""}) == ExcelRowType.FINAL_TOTAL_ROW
    assert classify_excel_row({"name": "Подпрограмма 1 Чистая вода", "program_code": "1"}) == ExcelRowType.SUBPROGRAM_ROW
    assert classify_excel_row({"name": "Основное мероприятие 01", "measure_code": "01"}) == ExcelRowType.MAIN_ACTIVITY_ROW
    assert classify_excel_row({"name": "Мероприятие 01.01", "measure_code": "01.01"}) == ExcelRowType.ACTIVITY_AGGREGATE_ROW
    assert classify_excel_row({"object_code": "1234567890.0000000001", "object_name": "ВЗУ Черусти"}) == ExcelRowType.OBJECT_LEAF_ROW
    assert classify_excel_row({"object_code": "0000000000.0000000000", "object_name": ""}) == ExcelRowType.UNASSIGNED_RESIDUAL_ROW

