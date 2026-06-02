---@diagnostic disable: undefined-field
describe('flux', function()
    before_each(function()
        package.loaded.flux = nil
    end)

    it('sets defaults and marks setup as done', function()
        ---@type Flux
        local flux = require('flux').setup()

        assert.is_true(flux.did_setup)
        assert.are.equal(false, flux.config.options.preview.wrap)
        assert.are.equal('stacked', flux.config.options.preview.diff_layout)
        assert.are.equal(0.3, flux.config.options.status.height)
    end)

    it('merges valid options without losing defaults', function()
        ---@type Flux
        local flux = require('flux').setup({
            preview = { show_metadata = false, diff_layout = 'split' },
            status = { height = 0.5 },
        })

        assert.are.equal(false, flux.config.options.preview.show_metadata)
        assert.are.equal('split', flux.config.options.preview.diff_layout)
        assert.are.equal(false, flux.config.options.preview.wrap)
        assert.are.equal(0.5, flux.config.options.status.height)
    end)

    it('rejects invalid setup options', function()
        assert.has_error(function()
            require('flux').setup({ preview = { diff_layout = 'wide' } })
        end, "opts.preview.diff_layout must be 'stacked', 'split', or 'auto'")

        assert.has_error(function()
            require('flux').setup({ status = { height = 2 } })
        end, 'opts.status.height must be a number between 0 and 1')
    end)
end)
