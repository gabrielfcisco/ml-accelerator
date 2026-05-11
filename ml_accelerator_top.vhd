library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Acelerador de ML (MLP) com 4 unidades MAC em paralelo.
-- Interface de barramento identica a do MPU original (ce_n/we_n/oe_n, address,
-- data inout, intr) para reaproveitar o host/testbench.
--
-- Mapa de memoria visto pelo host:
--   0x0000             cmd      (write: qualquer valor inicia execucao -> START)
--   0x0001             status   (read : bit0=busy, bit1=done)
--   0x0002             M        (numero de entradas por neuronio, <= 256)
--   0x0003             K        (numero de neuronios da camada, multiplo de 4, <= 64)
--   0x0100..0x01FF     input buffer (256 x 16 bits)
--   0x0400..0x07FF     weight buffer (4 bancos intercalados, addr[1:0]=banco,
--                                     addr[9:2]=linha; total 1024 pesos)
--   0x0800..0x083F     output buffer (64 x 16 bits, read)
--
-- Layout de pesos na memoria do host:
--   para grupo g (cobre neuronios 4g..4g+3) e entrada k:
--     w_neuron[4g+lane][k]  vai para  bank=lane, row=g*M+k
--   isto e, o host escreve 4 pesos consecutivos (banks 0..3) para cada par (g,k).
entity ml_accelerator_top is
    Port (
        ce_n    : in    std_logic;
        we_n    : in    std_logic;
        oe_n    : in    std_logic;
        intr    : out   std_logic;
        address : in    std_logic_vector(15 downto 0);
        data    : inout std_logic_vector(15 downto 0);
        clk     : in    std_logic;
        reset   : in    std_logic
    );
end ml_accelerator_top;

architecture rtl of ml_accelerator_top is

    -- Registradores de configuracao
    signal reg_M : std_logic_vector(15 downto 0) := (others => '0');
    signal reg_K : std_logic_vector(15 downto 0) := (others => '0');

    -- Decodificacao de endereco
    signal sel_cmd        : std_logic;
    signal sel_status     : std_logic;
    signal sel_M          : std_logic;
    signal sel_K          : std_logic;
    signal sel_input_buf  : std_logic;
    signal sel_weight_buf : std_logic;
    signal sel_output_buf : std_logic;

    signal host_write : std_logic;
    signal host_read  : std_logic;
    signal start      : std_logic;

    -- Input buffer
    signal in_we      : std_logic;
    signal in_wr_addr : std_logic_vector(7 downto 0);
    signal in_rd_addr : std_logic_vector(7 downto 0);
    signal in_rd_data : std_logic_vector(15 downto 0);

    -- Weight buffer
    signal w_we      : std_logic;
    signal w_bank    : std_logic_vector(1 downto 0);
    signal w_wr_addr : std_logic_vector(7 downto 0);
    signal w_rd_addr : std_logic_vector(7 downto 0);
    signal w_rd0     : std_logic_vector(15 downto 0);
    signal w_rd1     : std_logic_vector(15 downto 0);
    signal w_rd2     : std_logic_vector(15 downto 0);
    signal w_rd3     : std_logic_vector(15 downto 0);

    -- Output buffer
    signal out_we      : std_logic;
    signal out_wr_addr : std_logic_vector(5 downto 0);
    signal out_wr_data : std_logic_vector(15 downto 0);
    signal out_rd_addr : std_logic_vector(5 downto 0);
    signal out_rd_data : std_logic_vector(15 downto 0);

    -- MACs
    signal mac_clear : std_logic;
    signal mac_en    : std_logic;
    signal acc0      : std_logic_vector(31 downto 0);
    signal acc1      : std_logic_vector(31 downto 0);
    signal acc2      : std_logic_vector(31 downto 0);
    signal acc3      : std_logic_vector(31 downto 0);

    -- Status interno
    signal busy : std_logic;
    signal done : std_logic;

    -- Declaracao dos componentes
    component mac_unit
        Port (
            clk     : in  std_logic;
            reset   : in  std_logic;
            clear   : in  std_logic;
            en      : in  std_logic;
            a       : in  std_logic_vector(15 downto 0);
            b       : in  std_logic_vector(15 downto 0);
            acc_out : out std_logic_vector(31 downto 0)
        );
    end component;

    component input_buffer
        generic (DEPTH : integer := 256; ADDR_W : integer := 8);
        Port (
            clk     : in  std_logic;
            we      : in  std_logic;
            wr_addr : in  std_logic_vector(ADDR_W-1 downto 0);
            wr_data : in  std_logic_vector(15 downto 0);
            rd_addr : in  std_logic_vector(ADDR_W-1 downto 0);
            rd_data : out std_logic_vector(15 downto 0)
        );
    end component;

    component weight_buffer
        generic (BANK_DEPTH : integer := 256; ADDR_W : integer := 8);
        Port (
            clk      : in  std_logic;
            we       : in  std_logic;
            wr_bank  : in  std_logic_vector(1 downto 0);
            wr_addr  : in  std_logic_vector(ADDR_W-1 downto 0);
            wr_data  : in  std_logic_vector(15 downto 0);
            rd_addr  : in  std_logic_vector(ADDR_W-1 downto 0);
            rd_data0 : out std_logic_vector(15 downto 0);
            rd_data1 : out std_logic_vector(15 downto 0);
            rd_data2 : out std_logic_vector(15 downto 0);
            rd_data3 : out std_logic_vector(15 downto 0)
        );
    end component;

    component output_buffer
        generic (DEPTH : integer := 64; ADDR_W : integer := 6);
        Port (
            clk     : in  std_logic;
            we      : in  std_logic;
            wr_addr : in  std_logic_vector(ADDR_W-1 downto 0);
            wr_data : in  std_logic_vector(15 downto 0);
            rd_addr : in  std_logic_vector(ADDR_W-1 downto 0);
            rd_data : out std_logic_vector(15 downto 0)
        );
    end component;

    component accel_controller
        Port (
            clk         : in  std_logic;
            reset       : in  std_logic;
            start       : in  std_logic;
            M           : in  std_logic_vector(15 downto 0);
            K           : in  std_logic_vector(15 downto 0);
            in_rd_addr  : out std_logic_vector(7 downto 0);
            w_rd_addr   : out std_logic_vector(7 downto 0);
            mac_clear   : out std_logic;
            mac_en      : out std_logic;
            acc0        : in  std_logic_vector(31 downto 0);
            acc1        : in  std_logic_vector(31 downto 0);
            acc2        : in  std_logic_vector(31 downto 0);
            acc3        : in  std_logic_vector(31 downto 0);
            out_we      : out std_logic;
            out_wr_addr : out std_logic_vector(5 downto 0);
            out_wr_data : out std_logic_vector(15 downto 0);
            busy        : out std_logic;
            done        : out std_logic;
            intr        : out std_logic
        );
    end component;

begin

    -- Decodificacao de enderecos
    sel_cmd        <= '1' when address = x"0000" else '0';
    sel_status     <= '1' when address = x"0001" else '0';
    sel_M          <= '1' when address = x"0002" else '0';
    sel_K          <= '1' when address = x"0003" else '0';
    sel_input_buf  <= '1' when address(15 downto 8)  = x"01"        else '0';
    sel_weight_buf <= '1' when address(15 downto 10) = "000001"     else '0';
    sel_output_buf <= '1' when address(15 downto 6)  = "0000100000" else '0';

    host_write <= '1' when ce_n = '0' and we_n = '0' else '0';
    host_read  <= '1' when ce_n = '0' and oe_n = '0' else '0';

    -- Pulso de start enquanto o host estiver escrevendo em 0x0000.
    -- O controller so consome o pulso em S_IDLE; nas demais transicoes
    -- o flanco e ignorado, entao manter o sinal alto por varios ciclos e seguro.
    start <= '1' when host_write = '1' and sel_cmd = '1' else '0';

    -- Registradores de configuracao M e K
    process(clk, reset)
    begin
        if reset = '1' then
            reg_M <= (others => '0');
            reg_K <= (others => '0');
        elsif rising_edge(clk) then
            if host_write = '1' then
                if sel_M = '1' then
                    reg_M <= data;
                elsif sel_K = '1' then
                    reg_K <= data;
                end if;
            end if;
        end if;
    end process;

    -- Escritas nos buffers vindas do host
    in_we      <= host_write and sel_input_buf;
    in_wr_addr <= address(7 downto 0);

    w_we      <= host_write and sel_weight_buf;
    w_bank    <= address(1 downto 0);
    w_wr_addr <= address(9 downto 2);

    -- Leitura do output buffer (endereco vem do host)
    out_rd_addr <= address(5 downto 0);

    -- Driver tri-state do barramento de dados
    process(host_read, sel_status, sel_output_buf, busy, done, out_rd_data)
    begin
        if host_read = '1' and sel_status = '1' then
            data <= x"000" & "00" & done & busy;
        elsif host_read = '1' and sel_output_buf = '1' then
            data <= out_rd_data;
        else
            data <= (others => 'Z');
        end if;
    end process;

    -- Instancias
    U_INPUT_BUF : input_buffer
        port map (
            clk     => clk,
            we      => in_we,
            wr_addr => in_wr_addr,
            wr_data => data,
            rd_addr => in_rd_addr,
            rd_data => in_rd_data
        );

    U_WEIGHT_BUF : weight_buffer
        port map (
            clk      => clk,
            we       => w_we,
            wr_bank  => w_bank,
            wr_addr  => w_wr_addr,
            wr_data  => data,
            rd_addr  => w_rd_addr,
            rd_data0 => w_rd0,
            rd_data1 => w_rd1,
            rd_data2 => w_rd2,
            rd_data3 => w_rd3
        );

    U_OUTPUT_BUF : output_buffer
        port map (
            clk     => clk,
            we      => out_we,
            wr_addr => out_wr_addr,
            wr_data => out_wr_data,
            rd_addr => out_rd_addr,
            rd_data => out_rd_data
        );

    U_MAC0 : mac_unit
        port map (clk => clk, reset => reset, clear => mac_clear, en => mac_en,
                  a => in_rd_data, b => w_rd0, acc_out => acc0);
    U_MAC1 : mac_unit
        port map (clk => clk, reset => reset, clear => mac_clear, en => mac_en,
                  a => in_rd_data, b => w_rd1, acc_out => acc1);
    U_MAC2 : mac_unit
        port map (clk => clk, reset => reset, clear => mac_clear, en => mac_en,
                  a => in_rd_data, b => w_rd2, acc_out => acc2);
    U_MAC3 : mac_unit
        port map (clk => clk, reset => reset, clear => mac_clear, en => mac_en,
                  a => in_rd_data, b => w_rd3, acc_out => acc3);

    U_CTRL : accel_controller
        port map (
            clk         => clk,
            reset       => reset,
            start       => start,
            M           => reg_M,
            K           => reg_K,
            in_rd_addr  => in_rd_addr,
            w_rd_addr   => w_rd_addr,
            mac_clear   => mac_clear,
            mac_en      => mac_en,
            acc0        => acc0,
            acc1        => acc1,
            acc2        => acc2,
            acc3        => acc3,
            out_we      => out_we,
            out_wr_addr => out_wr_addr,
            out_wr_data => out_wr_data,
            busy        => busy,
            done        => done,
            intr        => intr
        );

end rtl;
