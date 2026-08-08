export type PageAction = {
  id: string
  label: string
  disabled?: boolean
  busy?: boolean
  run: () => void | Promise<void>
}
