// Mac'teki Core Data modelinin (DataModel v2) birebir karşılığı. Alan adları CloudKit kayıt alanlarıdır;
// Mac, iPhone ve Windows aynı kayıtları okuyup yazar.

export type Entity = 'Notebook' | 'Page' | 'Block' | 'Comment'
export type FieldType = 'STRING' | 'INT64' | 'BOOL' | 'DOUBLE' | 'TIMESTAMP' | 'ASSET'

export const ENTITIES: Entity[] = ['Notebook', 'Page', 'Block', 'Comment']
/** Ebeveyn önce uygulansın diye sıra */
export const ENTITY_ORDER: Record<Entity, number> = { Notebook: 0, Page: 1, Block: 2, Comment: 3 }
export const PARENT: Partial<Record<Entity, Entity>> = { Page: 'Notebook', Block: 'Page', Comment: 'Block' }

export const SCHEMA: Record<Entity, Record<string, FieldType>> = {
  Notebook: {
    name_: 'STRING', icon_: 'STRING', colorHex_: 'STRING', sortIndex: 'INT64', createdAt_: 'TIMESTAMP',
    modifiedAt_: 'TIMESTAMP',
  },
  Page: {
    title_: 'STRING', layout_: 'STRING', isPinned: 'BOOL', createdAt_: 'TIMESTAMP', updatedAt_: 'TIMESTAMP',
    drawing_: 'ASSET', authorName_: 'STRING', lastEditorName_: 'STRING', modifiedAt_: 'TIMESTAMP',
  },
  Block: {
    kind_: 'STRING', text_: 'STRING', order: 'DOUBLE', indent: 'INT64', createdAt_: 'TIMESTAMP',
    authorName_: 'STRING', isDone: 'BOOL', doneBy_: 'STRING', doneAt_: 'TIMESTAMP', doneNote_: 'STRING',
    assigneeID_: 'STRING', assigneeName_: 'STRING', assignedByID_: 'STRING', assignedByName_: 'STRING',
    dueDate_: 'TIMESTAMP', x: 'DOUBLE', y: 'DOUBLE', width: 'DOUBLE', isPlaced: 'BOOL',
    doneByID_: 'STRING', doneByName_: 'STRING', assignedAt_: 'TIMESTAMP', imageData_: 'ASSET',
    modifiedAt_: 'TIMESTAMP',
  },
  Comment: {
    text_: 'STRING', authorID_: 'STRING', authorName_: 'STRING', mentionIDs_: 'STRING', createdAt_: 'TIMESTAMP',
    modifiedAt_: 'TIMESTAMP',
  },
}

/** Core Data'daki varsayılanlar (alan boşsa) */
export const DEFAULTS: Partial<Record<string, unknown>> = {
  sortIndex: 0, isPinned: false, order: 0, indent: 0, isDone: false, x: 60, y: 60, width: 280, isPlaced: false,
}

/** Mac'teki CKCurrentUserDefaultName */
export const DEFAULT_OWNER = '__defaultOwner__'
