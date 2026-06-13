---@class IterPreviewBufferActions
---@field close_diff fun()
---@field jump_hunk fun(delta: integer)
---@field toggle_wrap fun()
---@field open_split_diff fun()
---@field stage_current_hunk fun()
---@field unstage_current_hunk fun()
---@field discard_current_hunk fun()
---@field goto_code fun()
---@field toggle_help fun()

---@class IterPreviewActions : IterPreviewBufferActions
---@field has_open_diff fun(): boolean
---@field focus_open_diff fun()
---@field refresh fun(state: GitStatusCursorState?)

return {}
